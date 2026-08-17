from datetime import date, datetime, time

import pytest

from planner.agenda import clashing, free_gaps, local_today, span
from planner.parsing import ParseError, parse_date, parse_entries, parse_entry, parse_time
from planner.storage import Plan, Storage

TODAY = date(2026, 8, 11)  # a Tuesday


def _plan(ref: int, start: time | None, end: time | None, day: date = TODAY) -> Plan:
    return Plan(id=ref, day=day, title=f"Plan {ref}", start=start, end=end, done=False)


def test_parses_a_timed_block():
    entry = parse_entry("9am-11am Gym", today=TODAY)
    assert (entry.day, entry.start, entry.end, entry.title) == (
        TODAY,
        time(9, 0),
        time(11, 0),
        "Gym",
    )


def test_parses_military_times_and_a_date():
    entry = parse_entry("14/8 1400-1600 project review", today=TODAY)
    assert (entry.day, entry.start, entry.end) == (date(2026, 8, 14), time(14, 0), time(16, 0))
    assert entry.title == "project review"


def test_parses_a_single_time_as_a_start():
    entry = parse_entry("tomorrow 12.30pm lunch with Ada", today=TODAY)
    assert entry.day == date(2026, 8, 12)
    assert (entry.start, entry.end) == (time(12, 30), None)
    assert entry.title == "lunch with Ada"


def test_a_line_without_a_time_is_a_task_for_today():
    entry = parse_entry("buy milk", today=TODAY)
    assert (entry.day, entry.start, entry.title) == (TODAY, None, "buy milk")


def test_weekday_names_look_forward():
    assert parse_date("friday", TODAY) == date(2026, 8, 14)
    assert parse_date("tue", TODAY) == TODAY
    assert parse_date("next tue", TODAY) == date(2026, 8, 18)


def test_parse_time_rejects_nonsense():
    with pytest.raises(ParseError):
        parse_time("banana")


def test_parses_several_lines_keeping_errors_per_line():
    results = parse_entries("9am-10am Gym\n\n   \n12pm lunch", today=TODAY)
    assert [line for line, _ in results] == ["9am-10am Gym", "12pm lunch"]
    assert all(not isinstance(outcome, ParseError) for _, outcome in results)


def test_untimed_plans_never_clash():
    assert clashing([_plan(1, None, None), _plan(2, None, None)]) == set()


def test_overlapping_blocks_are_flagged():
    plans = [_plan(1, time(9, 0), time(11, 0)), _plan(2, time(10, 0), time(12, 0))]
    assert clashing(plans) == {1, 2}


def test_a_single_time_takes_an_hour():
    start, end = span(_plan(1, time(9, 0), None))
    assert (start, end) == (datetime(2026, 8, 11, 9, 0), datetime(2026, 8, 11, 10, 0))


def test_free_gaps_are_what_is_left_of_the_waking_day():
    plans = [_plan(1, time(9, 0), time(11, 0)), _plan(2, time(14, 0), time(15, 0))]
    assert free_gaps(plans, TODAY) == [
        (time(8, 0), time(9, 0)),
        (time(11, 0), time(14, 0)),
        (time(15, 0), time(22, 0)),
    ]


def test_free_gaps_start_from_now_for_today():
    plans = [_plan(1, time(9, 0), time(11, 0))]
    assert free_gaps(plans, TODAY, after=time(12, 0)) == [(time(12, 0), time(22, 0))]


def test_local_today_follows_the_offset():
    late = datetime(2026, 8, 11, 17, 30)  # 01:30 the next day in GMT+8
    assert local_today(480, late) == date(2026, 8, 12)
    assert local_today(0, late) == date(2026, 8, 11)


def test_plans_are_numbered_from_one_per_user(tmp_path):
    storage = Storage(tmp_path / "planner.sqlite3")
    first = storage.add_plan(1, TODAY, "Gym", time(9, 0), time(10, 0))
    second = storage.add_plan(1, TODAY, "Lunch", time(12, 0), None)
    other_user = storage.add_plan(2, TODAY, "Standup", time(9, 0), None)
    assert (first, second, other_user) == (1, 2, 1)
    storage.close()


def test_a_day_lists_timed_plans_before_tasks(tmp_path):
    storage = Storage(tmp_path / "planner.sqlite3")
    storage.add_plan(1, TODAY, "buy milk", None, None)
    storage.add_plan(1, TODAY, "Gym", time(9, 0), time(10, 0))
    assert [plan.title for plan in storage.plans_on(1, TODAY)] == ["Gym", "buy milk"]
    storage.close()


def test_done_and_move_change_one_plan(tmp_path):
    storage = Storage(tmp_path / "planner.sqlite3")
    ref = storage.add_plan(1, TODAY, "Gym", time(9, 0), time(10, 0))
    assert storage.set_done(1, ref, True)
    assert storage.open_plans(1) == []
    storage.move_plan(1, ref, date(2026, 8, 12), time(18, 0), None)
    moved = storage.get_plan(1, ref)
    assert moved is not None
    assert (moved.day, moved.start, moved.end) == (date(2026, 8, 12), time(18, 0), None)
    storage.close()


def test_nudges_are_sent_once(tmp_path):
    storage = Storage(tmp_path / "planner.sqlite3")
    ref = storage.add_plan(1, TODAY, "Gym", time(9, 0), None)
    assert [plan.id for plan in storage.pending_nudges(1, TODAY)] == [ref]
    storage.mark_nudged(1, ref)
    assert storage.pending_nudges(1, TODAY) == []
    storage.close()


def test_clearing_a_day_leaves_other_days(tmp_path):
    storage = Storage(tmp_path / "planner.sqlite3")
    storage.add_plan(1, TODAY, "Gym", time(9, 0), None)
    storage.add_plan(1, date(2026, 8, 12), "Dentist", time(9, 0), None)
    assert storage.delete_plans(1, TODAY) == 1
    assert [plan.day for plan in storage.open_plans(1)] == [date(2026, 8, 12)]
    storage.close()
