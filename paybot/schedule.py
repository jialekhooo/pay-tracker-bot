"""Clash detection so the same time slot isn't double booked."""

from __future__ import annotations

from datetime import date, datetime, time, timedelta
from typing import Iterable

from .storage import ShiftRecord


def span(day: date, start: time, end: time) -> tuple[datetime, datetime]:
    """Absolute start/end, rolling the end into the next day when it wraps midnight."""
    start_dt = datetime.combine(day, start)
    end_dt = datetime.combine(day, end)
    if end_dt <= start_dt:
        end_dt += timedelta(days=1)
    return start_dt, end_dt


def find_clashes(
    records: Iterable[ShiftRecord], day: date, start: time, end: time
) -> list[ShiftRecord]:
    """Existing shifts whose time overlaps the given slot."""
    new_start, new_end = span(day, start, end)
    clashes = []
    for record in records:
        other_start, other_end = span(record.day, record.start, record.end)
        if new_start < other_end and other_start < new_end:
            clashes.append(record)
    return clashes
