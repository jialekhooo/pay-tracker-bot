"""SQLite persistence for shifts and per-user rate settings."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import date, time
from decimal import Decimal
from pathlib import Path

from .pay import RateConfig

DEFAULT_RATE = Decimal("15")
DEFAULT_CURRENCY = "SGD"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    user_id INTEGER PRIMARY KEY,
    default_rate TEXT NOT NULL,
    currency TEXT NOT NULL,
    overtime_after_hours TEXT,
    overtime_multiplier TEXT NOT NULL DEFAULT '1.5',
    default_break_hours TEXT NOT NULL DEFAULT '0',
    default_break_paid INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS event_rates (
    user_id INTEGER NOT NULL,
    event TEXT NOT NULL,
    rate TEXT NOT NULL,
    PRIMARY KEY (user_id, event)
);

CREATE TABLE IF NOT EXISTS shifts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    day TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    event TEXT NOT NULL,
    location TEXT NOT NULL DEFAULT '',
    break_hours TEXT NOT NULL DEFAULT '0',
    break_paid INTEGER NOT NULL DEFAULT 0,
    hours TEXT NOT NULL,
    pay TEXT NOT NULL,
    currency TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_shifts_user_day ON shifts (user_id, day);

CREATE TABLE IF NOT EXISTS reminders (
    user_id INTEGER PRIMARY KEY,
    chat_id INTEGER NOT NULL,
    send_at TEXT NOT NULL DEFAULT '20:00',
    utc_offset_minutes INTEGER NOT NULL DEFAULT 480,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_sent_on TEXT
);
"""


@dataclass(frozen=True)
class ShiftRecord:
    id: int
    day: date
    start: time
    end: time
    event: str
    location: str
    break_hours: Decimal
    break_paid: bool
    hours: Decimal
    pay: Decimal
    currency: str


@dataclass(frozen=True)
class Reminder:
    user_id: int
    chat_id: int
    send_at: time
    utc_offset_minutes: int
    enabled: bool
    last_sent_on: date | None


@dataclass(frozen=True)
class MonthSummary:
    month: str
    shifts: int
    hours: Decimal
    pay: Decimal
    currency: str


class Storage:
    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self._path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(_SCHEMA)
        self._migrate()
        self._conn.commit()

    def _migrate(self) -> None:
        """Add columns introduced after a database was first created."""
        additions = {
            "settings": {
                "default_break_hours": "TEXT NOT NULL DEFAULT '0'",
                "default_break_paid": "INTEGER NOT NULL DEFAULT 0",
            },
            "shifts": {
                "location": "TEXT NOT NULL DEFAULT ''",
                "break_hours": "TEXT NOT NULL DEFAULT '0'",
                "break_paid": "INTEGER NOT NULL DEFAULT 0",
            },
        }
        for table, columns in additions.items():
            existing = {
                row["name"] for row in self._conn.execute(f"PRAGMA table_info({table})")
            }
            for column, definition in columns.items():
                if column not in existing:
                    self._conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")

    def close(self) -> None:
        self._conn.close()

    def get_config(self, user_id: int) -> RateConfig:
        row = self._conn.execute(
            "SELECT * FROM settings WHERE user_id = ?", (user_id,)
        ).fetchone()
        rates = {
            r["event"]: Decimal(r["rate"])
            for r in self._conn.execute(
                "SELECT event, rate FROM event_rates WHERE user_id = ?", (user_id,)
            )
        }
        if row is None:
            return RateConfig(default_rate=DEFAULT_RATE, event_rates=rates)
        overtime = row["overtime_after_hours"]
        return RateConfig(
            default_rate=Decimal(row["default_rate"]),
            event_rates=rates,
            overtime_after_hours=Decimal(overtime) if overtime is not None else None,
            overtime_multiplier=Decimal(row["overtime_multiplier"]),
            currency=row["currency"],
            default_break_hours=Decimal(row["default_break_hours"]),
            default_break_paid=bool(row["default_break_paid"]),
        )

    def save_config(self, user_id: int, config: RateConfig) -> None:
        self._conn.execute(
            """
            INSERT INTO settings (user_id, default_rate, currency, overtime_after_hours,
                                  overtime_multiplier, default_break_hours, default_break_paid)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                default_rate = excluded.default_rate,
                currency = excluded.currency,
                overtime_after_hours = excluded.overtime_after_hours,
                overtime_multiplier = excluded.overtime_multiplier,
                default_break_hours = excluded.default_break_hours,
                default_break_paid = excluded.default_break_paid
            """,
            (
                user_id,
                str(config.default_rate),
                config.currency,
                None if config.overtime_after_hours is None else str(config.overtime_after_hours),
                str(config.overtime_multiplier),
                str(config.default_break_hours),
                int(config.default_break_paid),
            ),
        )
        self._conn.execute("DELETE FROM event_rates WHERE user_id = ?", (user_id,))
        self._conn.executemany(
            "INSERT INTO event_rates (user_id, event, rate) VALUES (?, ?, ?)",
            [(user_id, event, str(rate)) for event, rate in config.event_rates.items()],
        )
        self._conn.commit()

    def add_shift(
        self,
        user_id: int,
        day: date,
        start: time,
        end: time,
        event: str,
        break_hours: Decimal,
        break_paid: bool,
        hours: Decimal,
        pay: Decimal,
        currency: str,
        location: str = "",
    ) -> int:
        cursor = self._conn.execute(
            """
            INSERT INTO shifts (user_id, day, start_time, end_time, event, location,
                                break_hours, break_paid, hours, pay, currency)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                user_id,
                day.isoformat(),
                start.isoformat(timespec="minutes"),
                end.isoformat(timespec="minutes"),
                event,
                location,
                str(break_hours),
                int(break_paid),
                str(hours),
                str(pay),
                currency,
            ),
        )
        self._conn.commit()
        return int(cursor.lastrowid)

    def list_shifts(
        self, user_id: int, month: str | None = None, limit: int | None = None
    ) -> list[ShiftRecord]:
        query = "SELECT * FROM shifts WHERE user_id = ?"
        params: list[object] = [user_id]
        if month:
            query += " AND substr(day, 1, 7) = ?"
            params.append(month)
        query += " ORDER BY day DESC, start_time DESC, id DESC"
        if limit:
            query += " LIMIT ?"
            params.append(limit)
        return [_to_record(row) for row in self._conn.execute(query, params)]

    def shifts_between(self, user_id: int, first: date, last: date) -> list[ShiftRecord]:
        """Shifts whose date falls in [first, last], earliest first."""
        rows = self._conn.execute(
            """
            SELECT * FROM shifts
            WHERE user_id = ? AND day BETWEEN ? AND ?
            ORDER BY day ASC, start_time ASC, id ASC
            """,
            (user_id, first.isoformat(), last.isoformat()),
        )
        return [_to_record(row) for row in rows]

    def month_summaries(self, user_id: int) -> list[MonthSummary]:
        rows = self._conn.execute(
            """
            SELECT substr(day, 1, 7) AS month, COUNT(*) AS shifts,
                   SUM(CAST(hours AS REAL)) AS hours, SUM(CAST(pay AS REAL)) AS pay,
                   currency
            FROM shifts
            WHERE user_id = ?
            GROUP BY month
            ORDER BY month DESC
            """,
            (user_id,),
        )
        return [
            MonthSummary(
                month=row["month"],
                shifts=row["shifts"],
                hours=Decimal(str(row["hours"])),
                pay=Decimal(str(row["pay"])),
                currency=row["currency"],
            )
            for row in rows
        ]

    def get_reminder(self, user_id: int) -> Reminder | None:
        row = self._conn.execute(
            "SELECT * FROM reminders WHERE user_id = ?", (user_id,)
        ).fetchone()
        return None if row is None else _to_reminder(row)

    def save_reminder(
        self,
        user_id: int,
        chat_id: int,
        send_at: time,
        utc_offset_minutes: int,
        enabled: bool,
    ) -> None:
        self._conn.execute(
            """
            INSERT INTO reminders (user_id, chat_id, send_at, utc_offset_minutes, enabled)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                chat_id = excluded.chat_id,
                send_at = excluded.send_at,
                utc_offset_minutes = excluded.utc_offset_minutes,
                enabled = excluded.enabled
            """,
            (
                user_id,
                chat_id,
                send_at.isoformat(timespec="minutes"),
                utc_offset_minutes,
                int(enabled),
            ),
        )
        self._conn.commit()

    def enabled_reminders(self) -> list[Reminder]:
        rows = self._conn.execute("SELECT * FROM reminders WHERE enabled = 1")
        return [_to_reminder(row) for row in rows]

    def mark_reminder_sent(self, user_id: int, day: date) -> None:
        self._conn.execute(
            "UPDATE reminders SET last_sent_on = ? WHERE user_id = ?",
            (day.isoformat(), user_id),
        )
        self._conn.commit()

    def get_shift(self, user_id: int, shift_id: int) -> ShiftRecord | None:
        row = self._conn.execute(
            "SELECT * FROM shifts WHERE user_id = ? AND id = ?", (user_id, shift_id)
        ).fetchone()
        return None if row is None else _to_record(row)

    def delete_shift(self, user_id: int, shift_id: int) -> bool:
        cursor = self._conn.execute(
            "DELETE FROM shifts WHERE user_id = ? AND id = ?", (user_id, shift_id)
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def delete_shifts(self, user_id: int, month: str | None = None) -> int:
        query = "DELETE FROM shifts WHERE user_id = ?"
        params: list[object] = [user_id]
        if month:
            query += " AND substr(day, 1, 7) = ?"
            params.append(month)
        cursor = self._conn.execute(query, params)
        self._conn.commit()
        return cursor.rowcount


def _to_reminder(row: sqlite3.Row) -> Reminder:
    return Reminder(
        user_id=row["user_id"],
        chat_id=row["chat_id"],
        send_at=time.fromisoformat(row["send_at"]),
        utc_offset_minutes=row["utc_offset_minutes"],
        enabled=bool(row["enabled"]),
        last_sent_on=(
            date.fromisoformat(row["last_sent_on"]) if row["last_sent_on"] else None
        ),
    )


def _to_record(row: sqlite3.Row) -> ShiftRecord:
    return ShiftRecord(
        id=row["id"],
        day=date.fromisoformat(row["day"]),
        start=time.fromisoformat(row["start_time"]),
        end=time.fromisoformat(row["end_time"]),
        event=row["event"],
        location=row["location"] or "",
        break_hours=Decimal(row["break_hours"]),
        break_paid=bool(row["break_paid"]),
        hours=Decimal(row["hours"]),
        pay=Decimal(row["pay"]),
        currency=row["currency"],
    )
