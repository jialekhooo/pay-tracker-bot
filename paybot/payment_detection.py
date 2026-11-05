from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from email.utils import parseaddr

SGT = timezone(timedelta(hours=8))
DBS_SENDER = "ibanking.alert@dbs.com"
DBS_SUBJECT = "digibank Alerts - You've received a transfer"
SCHEMA = """
CREATE TABLE IF NOT EXISTS payment_connections (
 user_id INTEGER PRIMARY KEY, email TEXT UNIQUE, refresh_token TEXT,
 connected_at INTEGER NOT NULL DEFAULT 0, last_scan INTEGER NOT NULL DEFAULT 0,
 auto_since INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS payment_oauth (
 token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL,
 stage TEXT NOT NULL, browser_hash TEXT, expires INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS payment_rules (
 id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
 payer TEXT NOT NULL, event TEXT NOT NULL, UNIQUE(user_id, payer, event)
);
CREATE TABLE IF NOT EXISTS payment_receipts (
 id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
 message_id TEXT NOT NULL, receipt_key TEXT NOT NULL, amount TEXT,
 currency TEXT NOT NULL DEFAULT 'SGD', payer TEXT NOT NULL DEFAULT '',
 received_at TEXT, account_last4 TEXT NOT NULL DEFAULT '', trusted INTEGER NOT NULL,
 status TEXT NOT NULL, reason TEXT NOT NULL, event TEXT,
 created_at INTEGER NOT NULL, UNIQUE(user_id, message_id), UNIQUE(user_id, receipt_key)
);
CREATE TABLE IF NOT EXISTS payment_allocations (
 receipt_id INTEGER NOT NULL, user_id INTEGER NOT NULL, shift_id INTEGER NOT NULL,
 snapshot TEXT NOT NULL, PRIMARY KEY(receipt_id, shift_id)
);
CREATE TABLE IF NOT EXISTS payment_audit (
 id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
 receipt_id INTEGER NOT NULL, action TEXT NOT NULL, created_at INTEGER NOT NULL
);
"""


def normalized(value: str) -> str:
    return " ".join(value.casefold().split())


def parse_dbs_alert(subject: str, sender: str, text: str) -> dict | None:
    if parseaddr(sender)[1].casefold() != DBS_SENDER:
        return None
    subject = subject.replace("’", "'").strip()
    if subject.casefold() != DBS_SUBJECT.casefold():
        return None
    match = re.search(
        r"You have received\s+SGD\s+((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})\s+via FAST transfer on\s+"
        r"(\d{1,2}\s+[A-Za-z]{3}\s+\d{4}\s+\d{2}:\d{2})\s+SGT", text, re.I,
    )
    payer = re.search(r"(?:^|\n)\s*From:\s*([^\r\n]+)", text, re.I)
    account = re.search(r"To:\s*Your DBS/POSB account ending\s+(\d{4})\b", text, re.I)
    reference = re.search(r"Transaction Ref:\s*([^\r\n]+)", text, re.I)
    reference_value = reference.group(1).strip() if reference else ""
    if reference_value.lower().startswith("dear "):
        reference_value = ""
    received_at = None
    if match:
        try:
            received_at = datetime.strptime(match[2], "%d %b %Y %H:%M").replace(tzinfo=SGT)
        except ValueError:
            pass
    amount = Decimal(match[1].replace(",", "")) if match else None
    reason = "" if amount and received_at and payer and account else "Incomplete DBS alert; review the original email."
    if amount is not None and amount <= 0:
        reason = "Transfer amount must be positive."
    fields = {
        "amount": str(amount) if amount is not None else None,
        "currency": "SGD", "payer": payer[1].strip()[:200] if payer else "",
        "received_at": received_at.isoformat() if received_at else None,
        "account_last4": account[1] if account else "", "reason": reason,
    }
    key = ("ref:" + reference_value) if reference_value else json.dumps(fields, sort_keys=True)
    fields["receipt_key"] = hashlib.sha256(key.encode()).hexdigest()
    return fields


def gmail_authenticated(headers: list[dict], labels: list[str]) -> bool:
    if set(labels) & {"SPAM", "TRASH", "SENT", "DRAFT"}:
        return False
    results = [h["value"] for h in headers if h["name"].lower() == "authentication-results"]
    for result in results:
        if not re.match(r"\s*mx\.google\.com\s*;", result, re.I):
            continue
        return bool(
            re.search(r"\bdmarc=pass\b[^;]*\bheader\.from=dbs\.com(?=[\s;)])", result, re.I)
            and re.search(r"\bdkim=pass\b[^;]*\bheader\.(?:i=@|d=)dbs\.com(?=[\s;)])", result, re.I)
        )
    return False


class PaymentStore:
    def __init__(self, storage):
        self.storage = storage
        self.db: sqlite3.Connection = storage._conn
        self.db.executescript(SCHEMA)

    def connection(self, user_id: int) -> dict | None:
        row = self.db.execute("SELECT * FROM payment_connections WHERE user_id=?", (user_id,)).fetchone()
        return dict(row) if row else None

    def save_connection(self, user_id: int, email: str, encrypted_token: str) -> None:
        with self.db:
            self.db.execute(
                "INSERT INTO payment_connections(user_id,email,refresh_token,connected_at) VALUES(?,?,?,?) "
                "ON CONFLICT(user_id) DO UPDATE SET email=excluded.email,refresh_token=excluded.refresh_token,"
                "connected_at=excluded.connected_at,last_scan=0,auto_since=0,error=''",
                (user_id, email.casefold(), encrypted_token, int(time.time())),
            )

    def rules(self, user_id: int) -> list[dict]:
        return [dict(r) for r in self.db.execute(
            "SELECT id,payer,event FROM payment_rules WHERE user_id=? ORDER BY payer,event", (user_id,)
        )]

    def save_rule(self, user_id: int, payer: str, event: str) -> None:
        payer, event = normalized(payer), event.strip()
        if not payer or len(payer) > 200 or len(event) > 120:
            raise ValueError("Enter a payer name and select an event.")
        if not self.storage.shifts_for_event(user_id, event):
            raise ValueError("Event not found.")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO payment_rules(user_id,payer,event) VALUES(?,?,?)", (user_id, payer, event))

    def set_event_payer(self, user_id: int, event: str, payer: str) -> None:
        event, payer = event.strip(), normalized(payer)
        if not event or len(event) > 120 or len(payer) > 200:
            raise ValueError("Enter a valid event and company name.")
        shifts = self.storage.shifts_for_event(user_id, event)
        if not shifts:
            raise ValueError("Event not found.")
        event = shifts[0].event
        with self.db:
            self.db.execute("DELETE FROM payment_rules WHERE user_id=? AND lower(event)=lower(?)", (user_id, event))
            if payer:
                self.db.execute("INSERT INTO payment_rules(user_id,payer,event) VALUES(?,?,?)", (user_id, payer, event))

    def payer_suggestions(self, user_id: int) -> list[str]:
        allowed = self.allowed_payers(user_id)
        names = [row[0] for row in self.db.execute(
            "SELECT payer FROM payment_receipts WHERE user_id=? AND trusted=1 AND payer<>'' "
            "GROUP BY payer ORDER BY MAX(created_at) DESC LIMIT 100", (user_id,),
        )]
        names.extend(rule["payer"] for rule in self.rules(user_id))
        unique = {}
        for name in names:
            if normalized(name) in allowed:
                unique.setdefault(normalized(name), name)
        return list(unique.values())[:100]

    def allowed_payers(self, user_id: int) -> set[str]:
        return {normalized(rule["payer"]) for rule in self.rules(user_id)}

    def accepts_payer(self, user_id: int, payer: str) -> bool:
        return bool(payer and normalized(payer) in self.allowed_payers(user_id))

    def candidates(self, user_id: int, receipt: dict) -> list[dict]:
        if not receipt.get("amount") or not receipt.get("received_at"):
            return []
        received = datetime.fromisoformat(receipt["received_at"])
        reminder = self.storage.get_reminder(user_id)
        shift_zone = timezone(timedelta(minutes=reminder.utc_offset_minutes if reminder else 480))
        groups: dict[str, list] = {}
        all_groups: dict[str, list] = {}
        allocated_refs = {row[0] for row in self.db.execute(
            "SELECT s.ref FROM shifts s JOIN payment_allocations a ON a.shift_id=s.id "
            "JOIN payment_receipts r ON r.id=a.receipt_id "
            "WHERE s.user_id=? AND a.user_id=? AND r.status IN ('auto_paid','confirmed_paid')",
            (user_id, user_id),
        )}
        for shift in self.storage.list_shifts(user_id):
            all_groups.setdefault(shift.event.casefold(), []).append(shift)
        for key, shifts in all_groups.items():
            ends = [datetime.combine(s.day, s.end, shift_zone) + (timedelta(days=1) if s.end <= s.start else timedelta()) for s in shifts]
            if any(s.paid or s.id in allocated_refs or s.currency != receipt["currency"] for s in shifts) or max(ends) > received:
                continue
            groups[key] = shifts
        candidates = []
        rules = self.rules(user_id)
        for key, shifts in groups.items():
            earnings = sum((s.pay for s in shifts), Decimal(0))
            cab = sum((c.amount for c in self.storage.cab_claims(user_id) if c.event and c.event.casefold() == key and c.currency == receipt["currency"]), Decimal(0))
            if Decimal(receipt["amount"]) not in {earnings, earnings + cab}:
                continue
            candidates.append({
                "event": shifts[0].event, "shift_ids": [s.id for s in shifts],
                "payer_match": any(r["payer"] == normalized(receipt["payer"]) and r["event"].casefold() == key for r in rules),
                "includes_cab": bool(cab and Decimal(receipt["amount"]) == earnings + cab),
            })
        return candidates

    def ingest(self, user_id: int, message_id: str, parsed: dict, trusted: bool) -> int:
        with self.db:
            self.db.execute(
                "INSERT OR IGNORE INTO payment_receipts(user_id,message_id,receipt_key,amount,currency,payer,received_at,"
                "account_last4,trusted,status,reason,created_at) VALUES(?,?,?,?,?,?,?,?,?,'review',?,?)",
                (user_id, message_id, parsed["receipt_key"], parsed["amount"], parsed["currency"], parsed["payer"],
                 parsed["received_at"], parsed["account_last4"], int(trusted), parsed["reason"], int(time.time())),
            )
            created = self.db.execute("SELECT changes()").fetchone()[0]
            receipt = dict(self.db.execute("SELECT * FROM payment_receipts WHERE user_id=? AND (message_id=? OR receipt_key=?)", (user_id, message_id, parsed["receipt_key"])).fetchone())
            if not created:
                return receipt["id"]
            choices = self.candidates(user_id, receipt)
            matched = [c for c in choices if c["payer_match"]]
            connection = self.connection(user_id)
            since = connection["auto_since"] if connection else 0
            timestamp = datetime.fromisoformat(receipt["received_at"]).timestamp() if receipt["received_at"] else 0
            if trusted and not parsed["reason"] and since and timestamp >= since and len(matched) == 1:
                self._apply(user_id, receipt, matched[0], "auto_paid")
            else:
                reason = parsed["reason"] or (
                    "Email authentication could not be verified." if not trusted else
                    "Multiple payer matches; choose the correct event." if len(matched) > 1 else
                    "Exact amount found; confirm the event or add a payer rule." if choices else
                    "No exact unpaid event total found. Partial and combined payments need manual reconciliation."
                )
                self.db.execute("UPDATE payment_receipts SET reason=? WHERE id=?", (reason, receipt["id"]))
            return receipt["id"]

    def receipt(self, user_id: int, receipt_id: int) -> dict:
        row = self.db.execute("SELECT * FROM payment_receipts WHERE user_id=? AND id=?", (user_id, receipt_id)).fetchone()
        if not row:
            raise ValueError("Payment alert not found.")
        return dict(row)

    def _apply(self, user_id: int, receipt: dict, candidate: dict, action: str) -> None:
        ids = candidate["shift_ids"]
        for shift in self.storage.list_shifts(user_id):
            if shift.id not in ids:
                continue
            raw = self.db.execute("SELECT id FROM shifts WHERE user_id=? AND ref=?", (user_id, shift.id)).fetchone()
            if not raw:
                raise ValueError("A linked shift no longer exists.")
            database_id = raw["id"]
            snapshot = json.dumps({"day": shift.day.isoformat(), "start_time": shift.start.isoformat(), "end_time": shift.end.isoformat(), "event": shift.event, "pay": str(shift.pay), "currency": shift.currency}, sort_keys=True)
            self.db.execute("INSERT INTO payment_allocations VALUES(?,?,?,?)", (receipt["id"], user_id, database_id, snapshot))
            cursor = self.db.execute("UPDATE shifts SET paid=1 WHERE id=? AND user_id=? AND paid=0", (database_id, user_id))
            if cursor.rowcount != 1:
                raise ValueError("The shifts changed. Refresh and review this alert again.")
        self.db.execute("UPDATE payment_receipts SET status=?,event=?,reason=? WHERE id=?", (action, candidate["event"], "Matched exact event total and currency.", receipt["id"]))
        self.db.execute("INSERT INTO payment_audit(user_id,receipt_id,action,created_at) VALUES(?,?,?,?)", (user_id, receipt["id"], action, int(time.time())))

    def confirm(self, user_id: int, receipt_id: int, event: str) -> None:
        with self.db:
            receipt = self.receipt(user_id, receipt_id)
            if receipt["status"] != "review" or not receipt["trusted"] or receipt["reason"].startswith("Incomplete"):
                raise ValueError("This alert cannot be applied. Check the original email.")
            choice = next((c for c in self.candidates(user_id, receipt) if c["event"].casefold() == event.casefold()), None)
            if not choice:
                raise ValueError("The event total no longer matches this alert.")
            self._apply(user_id, receipt, choice, "confirmed_paid")

    def dismiss(self, user_id: int, receipt_id: int) -> None:
        with self.db:
            receipt = self.receipt(user_id, receipt_id)
            if receipt["status"] != "review":
                raise ValueError("Only alerts awaiting review can be dismissed.")
            self.db.execute("UPDATE payment_receipts SET status='dismissed' WHERE id=?", (receipt_id,))
            self.db.execute("INSERT INTO payment_audit(user_id,receipt_id,action,created_at) VALUES(?,?,'dismissed',?)", (user_id, receipt_id, int(time.time())))

    def undo(self, user_id: int, receipt_id: int) -> None:
        with self.db:
            receipt = self.receipt(user_id, receipt_id)
            if receipt["status"] not in {"auto_paid", "confirmed_paid"}:
                raise ValueError("This payment has already been undone or was not applied.")
            allocations = self.db.execute("SELECT * FROM payment_allocations WHERE user_id=? AND receipt_id=?", (user_id, receipt_id)).fetchall()
            for allocation in allocations:
                row = self.db.execute("SELECT * FROM shifts WHERE id=? AND user_id=?", (allocation["shift_id"], user_id)).fetchone()
                expected = json.loads(allocation["snapshot"])
                if not row or not row["paid"] or any(
                    (str(row[k])[:5] != v[:5]) if k in {"start_time", "end_time"} else str(row[k]) != v
                    for k, v in expected.items()
                ):
                    raise ValueError("A linked shift changed. Review it manually before undoing.")
            for allocation in allocations:
                self.db.execute("UPDATE shifts SET paid=0 WHERE id=? AND user_id=?", (allocation["shift_id"], user_id))
            self.db.execute("UPDATE payment_receipts SET status='undone' WHERE id=?", (receipt_id,))
            self.db.execute("INSERT INTO payment_audit(user_id,receipt_id,action,created_at) VALUES(?,?,'undone',?)", (user_id, receipt_id, int(time.time())))

    def status(self, user_id: int) -> dict:
        conn = self.connection(user_id)
        receipts = []
        allowed = self.allowed_payers(user_id)
        for row in self.db.execute("SELECT * FROM payment_receipts WHERE user_id=? ORDER BY id DESC", (user_id,)):
            item = dict(row)
            if normalized(item["payer"]) not in allowed and not item["event"]:
                continue
            item.pop("receipt_key")
            item.pop("message_id")
            item.pop("user_id")
            item["candidates"] = [c for c in self.candidates(user_id, item) if c["payer_match"]] if item["status"] == "review" and item["trusted"] else []
            receipts.append(item)
            if len(receipts) == 50:
                break
        return {
            "connected": bool(conn and conn["refresh_token"]), "email": conn["email"] if conn else None,
            "auto_enabled": bool(conn and conn["auto_since"]), "last_scan": conn["last_scan"] if conn else 0,
            "error": conn["error"] if conn else "", "rules": self.rules(user_id), "receipts": receipts,
            "events": sorted({s.event for s in self.storage.list_shifts(user_id)}, key=str.casefold),
        }
