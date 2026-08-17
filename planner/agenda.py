"""Turning stored plans into a day: clashes, gaps and the local clock."""

from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone

from .storage import Plan

DEFAULT_LENGTH = timedelta(hours=1)
DAY_START = time(8, 0)
DAY_END = time(22, 0)
SHORTEST_GAP = timedelta(minutes=30)


def local_now(utc_offset_minutes: int, now_utc: datetime | None = None) -> datetime:
    """The wall clock where the user is — the server itself runs on UTC."""
    now = now_utc or datetime.now(timezone.utc).replace(tzinfo=None)
    return now + timedelta(minutes=utc_offset_minutes)


def local_today(utc_offset_minutes: int, now_utc: datetime | None = None) -> date:
    return local_now(utc_offset_minutes, now_utc).date()


def span(plan: Plan) -> tuple[datetime, datetime]:
    """Absolute start and end, an hour long by default and rolling over midnight."""
    if plan.start is None:
        raise ValueError("An untimed plan has no span")
    start = datetime.combine(plan.day, plan.start)
    if plan.end is None:
        return start, start + DEFAULT_LENGTH
    end = datetime.combine(plan.day, plan.end)
    if end <= start:
        end += timedelta(days=1)
    return start, end


def clashing(plans: list[Plan]) -> set[int]:
    """The numbers of the plans that overlap another one."""
    timed = [plan for plan in plans if plan.timed]
    clashes: set[int] = set()
    for index, plan in enumerate(timed):
        start, end = span(plan)
        for other in timed[index + 1 :]:
            other_start, other_end = span(other)
            if start < other_end and other_start < end:
                clashes.update({plan.id, other.id})
    return clashes


def free_gaps(
    plans: list[Plan],
    day: date,
    after: time | None = None,
) -> list[tuple[time, time]]:
    """The stretches of the waking day nothing is booked into yet."""
    opening = max(after, DAY_START) if after else DAY_START
    cursor = datetime.combine(day, opening)
    closing = datetime.combine(day, DAY_END)
    gaps: list[tuple[time, time]] = []
    for plan in sorted((p for p in plans if p.timed), key=lambda p: p.start or time()):
        start, end = span(plan)
        if start - cursor >= SHORTEST_GAP:
            gaps.append((cursor.time(), start.time()))
        cursor = max(cursor, min(end, closing))
    if closing - cursor >= SHORTEST_GAP:
        gaps.append((cursor.time(), closing.time()))
    return gaps
