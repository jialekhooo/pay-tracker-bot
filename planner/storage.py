"""SQLite persistence for plans and per-user reminder settings."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import date, time
from pathlib import Path

DEFAULT_UTC_OFFSET_MINUTES = 480  # GMT+8
DEFAULT_AGENDA_AT = time(8, 0)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ref INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    day TEXT NOT NULL,
    start_time TEXT,
    end_time TEXT,
    title TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0,
    nudged INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_plans_user_day ON plans (user_id, day);

CREATE TABLE IF NOT EXISTS reminders (
    user_id INTEGER PRIMARY KEY,
    chat_id INTEGER NOT NULL,
    agenda_at TEXT NOT NULL DEFAULT '08:00',
    utc_offset_minutes INTEGER NOT NULL DEFAULT 480,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_sent_on TEXT
);
"""


@dataclass(frozen=True)
class Plan:
    id: int
    day: date
    title: str
    start: time | None
    end: time | None
    done: bool

    @property
    def timed(self) -> bool:
        return self.start is not None


@dataclass(frozen=True)
class Reminder:
    user_id: int
    chat_id: int
    agenda_at: time
    utc_offset_minutes: int
    enabled: bool
    last_sent_on: date | None


class Storage:
    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self._path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.executescript(_SCHEMA)
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()

    def add_plan(
        self,
        user_id: int,
        day: date,
        title: str,
        start: time | None,
        end: time | None,
    ) -> int:
        """Store a plan and hand back its number, which counts from 1 per user."""
        ref = int(
            self._conn.execute(
                "SELECT COALESCE(MAX(ref), 0) + 1 FROM plans WHERE user_id = ?", (user_id,)
            ).fetchone()[0]
        )
        self._conn.execute(
            """
            INSERT INTO plans (ref, user_id, day, start_time, end_time, title)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                ref,
                user_id,
                day.isoformat(),
                None if start is None else start.isoformat(timespec="minutes"),
                None if end is None else end.isoformat(timespec="minutes"),
                title,
            ),
        )
        self._conn.commit()
        return ref

    def plans_on(self, user_id: int, day: date) -> list[Plan]:
        return self.plans_between(user_id, day, day)

    def plans_between(self, user_id: int, first: date, last: date) -> list[Plan]:
        """Plans in [first, last], timed ones first and in clock order."""
        rows = self._conn.execute(
            """
            SELECT * FROM plans
            WHERE user_id = ? AND day BETWEEN ? AND ?
            ORDER BY day ASC, start_time IS NULL, start_time ASC, ref ASC
            """,
            (user_id, first.isoformat(), last.isoformat()),
        )
        return [_to_plan(row) for row in rows]

    def open_plans(self, user_id: int) -> list[Plan]:
        """Everything not ticked off yet, oldest first."""
        rows = self._conn.execute(
            """
            SELECT * FROM plans
            WHERE user_id = ? AND done = 0
            ORDER BY day ASC, start_time IS NULL, start_time ASC, ref ASC
            """,
            (user_id,),
        )
        return [_to_plan(row) for row in rows]

    def get_plan(self, user_id: int, ref: int) -> Plan | None:
        row = self._conn.execute(
            "SELECT * FROM plans WHERE user_id = ? AND ref = ?", (user_id, ref)
        ).fetchone()
        return None if row is None else _to_plan(row)

    def set_done(self, user_id: int, ref: int, done: bool) -> bool:
        cursor = self._conn.execute(
            "UPDATE plans SET done = ? WHERE user_id = ? AND ref = ?",
            (int(done), user_id, ref),
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def move_plan(
        self,
        user_id: int,
        ref: int,
        day: date,
        start: time | None,
        end: time | None,
    ) -> bool:
        cursor = self._conn.execute(
            """
            UPDATE plans SET day = ?, start_time = ?, end_time = ?, nudged = 0
            WHERE user_id = ? AND ref = ?
            """,
            (
                day.isoformat(),
                None if start is None else start.isoformat(timespec="minutes"),
                None if end is None else end.isoformat(timespec="minutes"),
                user_id,
                ref,
            ),
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def delete_plan(self, user_id: int, ref: int) -> bool:
        cursor = self._conn.execute(
            "DELETE FROM plans WHERE user_id = ? AND ref = ?", (user_id, ref)
        )
        self._conn.commit()
        return cursor.rowcount > 0

    def delete_plans(self, user_id: int, day: date | None = None) -> int:
        query = "DELETE FROM plans WHERE user_id = ?"
        params: list[object] = [user_id]
        if day is not None:
            query += " AND day = ?"
            params.append(day.isoformat())
        cursor = self._conn.execute(query, params)
        self._conn.commit()
        return cursor.rowcount

    def get_reminder(self, user_id: int) -> Reminder | None:
        row = self._conn.execute(
            "SELECT * FROM reminders WHERE user_id = ?", (user_id,)
        ).fetchone()
        return None if row is None else _to_reminder(row)

    def save_reminder(
        self,
        user_id: int,
        chat_id: int,
        agenda_at: time,
        utc_offset_minutes: int,
        enabled: bool,
    ) -> None:
        self._conn.execute(
            """
            INSERT INTO reminders (user_id, chat_id, agenda_at, utc_offset_minutes, enabled)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                chat_id = excluded.chat_id,
                agenda_at = excluded.agenda_at,
                utc_offset_minutes = excluded.utc_offset_minutes,
                enabled = excluded.enabled
            """,
            (
                user_id,
                chat_id,
                agenda_at.isoformat(timespec="minutes"),
                utc_offset_minutes,
                int(enabled),
            ),
        )
        self._conn.commit()

    def enabled_reminders(self) -> list[Reminder]:
        rows = self._conn.execute("SELECT * FROM reminders WHERE enabled = 1")
        return [_to_reminder(row) for row in rows]

    def mark_agenda_sent(self, user_id: int, day: date) -> None:
        self._conn.execute(
            "UPDATE reminders SET last_sent_on = ? WHERE user_id = ?",
            (day.isoformat(), user_id),
        )
        self._conn.commit()

    def mark_nudged(self, user_id: int, ref: int) -> None:
        self._conn.execute(
            "UPDATE plans SET nudged = 1 WHERE user_id = ? AND ref = ?", (user_id, ref)
        )
        self._conn.commit()

    def pending_nudges(self, user_id: int, day: date) -> list[Plan]:
        """Timed plans for the day that haven't had their heads-up yet."""
        rows = self._conn.execute(
            """
            SELECT * FROM plans
            WHERE user_id = ? AND day = ? AND start_time IS NOT NULL
                  AND done = 0 AND nudged = 0
            ORDER BY start_time ASC
            """,
            (user_id, day.isoformat()),
        )
        return [_to_plan(row) for row in rows]


def _to_plan(row: sqlite3.Row) -> Plan:
    return Plan(
        id=row["ref"],
        day=date.fromisoformat(row["day"]),
        title=row["title"],
        start=time.fromisoformat(row["start_time"]) if row["start_time"] else None,
        end=time.fromisoformat(row["end_time"]) if row["end_time"] else None,
        done=bool(row["done"]),
    )


def _to_reminder(row: sqlite3.Row) -> Reminder:
    return Reminder(
        user_id=row["user_id"],
        chat_id=row["chat_id"],
        agenda_at=time.fromisoformat(row["agenda_at"]),
        utc_offset_minutes=row["utc_offset_minutes"],
        enabled=bool(row["enabled"]),
        last_sent_on=date.fromisoformat(row["last_sent_on"]) if row["last_sent_on"] else None,
    )
