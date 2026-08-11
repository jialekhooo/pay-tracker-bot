from datetime import date, time
from decimal import Decimal

import pytest

from paybot.bot import parse_month
from paybot.parsing import ParseError, Shift, parse_shift, parse_shifts
from paybot.pay import RateConfig, calculate_pay
from paybot.storage import Storage

TODAY = date(2026, 8, 11)


def test_parse_iso_format():
    shift = parse_shift("2026-08-12 18:00 23:30 Wedding gig", today=TODAY)
    assert shift.day == date(2026, 8, 12)
    assert shift.start == time(18, 0)
    assert shift.end == time(23, 30)
    assert shift.event == "Wedding gig"
    assert shift.hours == 5.5


def test_parse_compact_12_hour_format():
    shift = parse_shift("12/8 6pm-11.30pm Wedding gig", today=TODAY)
    assert shift.day == date(2026, 8, 12)
    assert shift.start == time(18, 0)
    assert shift.end == time(23, 30)


def test_parse_today_and_word_separator():
    shift = parse_shift("today 9am to 5pm Roadshow", today=TODAY)
    assert shift.day == TODAY
    assert shift.hours == 8


def test_overnight_shift_wraps_past_midnight():
    shift = parse_shift("today 10pm - 2am Night event", today=TODAY)
    assert shift.hours == 4


def test_parse_rejects_incomplete_input():
    with pytest.raises(ParseError):
        parse_shift("today 9am Roadshow", today=TODAY)


def test_calculate_pay_uses_event_rate():
    config = RateConfig(
        default_rate=Decimal("15"), event_rates={"wedding gig": Decimal("25")}
    )
    assert calculate_pay(5.5, "Wedding gig", config) == Decimal("137.50")
    assert calculate_pay(5.5, "Other", config) == Decimal("82.50")


def test_calculate_pay_applies_overtime():
    config = RateConfig(
        default_rate=Decimal("10"),
        event_rates={},
        overtime_after_hours=Decimal("8"),
        overtime_multiplier=Decimal("1.5"),
    )
    assert calculate_pay(10, "Shift", config) == Decimal("110.00")


@pytest.mark.parametrize(
    "text, expected_hours, expected_paid",
    [
        ("today 9am-6pm 1h unpaid break Roadshow", 8, False),
        ("today 9am-6pm 1 hour paid break Roadshow", 9, True),
        ("today 9am-6pm with 30 min unpaid break Roadshow", 8.5, False),
        ("today 9am-6pm unpaid 1hr break Roadshow", 8, False),
        ("today 9am-6pm 1h break unpaid Roadshow", 8, False),
    ],
)
def test_break_detection(text, expected_hours, expected_paid):
    shift = parse_shift(text, today=TODAY)
    assert shift.event == "Roadshow"
    assert shift.hours == expected_hours
    assert shift.rest.paid is expected_paid
    assert shift.break_specified is True


def test_break_without_marker_uses_default_paid_flag():
    unpaid = parse_shift("today 9am-6pm 1h break Roadshow", today=TODAY)
    assert unpaid.hours == 8 and unpaid.rest.paid is False
    paid = parse_shift("today 9am-6pm 1h break Roadshow", today=TODAY, default_break_paid=True)
    assert paid.hours == 9 and paid.rest.paid is True


def test_no_break_phrase_is_explicit():
    shift = parse_shift("today 9am-6pm no break Roadshow", today=TODAY)
    assert shift.hours == 9
    assert shift.break_specified is True


def test_shift_without_break_is_unspecified():
    shift = parse_shift("today 9am-6pm Roadshow", today=TODAY)
    assert shift.break_specified is False
    assert shift.hours == 9


def test_inline_rate_override():
    shift = parse_shift("13/8 8.30am - 8pm 15/h Hermes Private Sale", today=TODAY)
    assert shift.day == date(2026, 8, 13)
    assert shift.start == time(8, 30)
    assert shift.end == time(20, 0)
    assert shift.event == "Hermes Private Sale"
    assert shift.rate_override == Decimal("15")
    config = RateConfig(default_rate=Decimal("10"), event_rates={})
    assert calculate_pay(shift.hours, shift.event, config, shift.rate_override) == Decimal(
        "172.50"
    )


def test_parse_multiple_lines():
    text = """13/8 8.30am - 8pm 15/h Hermes Private Sale
14/8 9am - 8pm 15/h Hermes Private Sale
15/8 9am - 9pm 15/h Hermes Private Sale
16/8 7.45am - 8pm 15/h Hermes Private Sale"""
    results = parse_shifts(text, today=TODAY)
    assert len(results) == 4
    shifts = [shift for _, shift in results]
    assert all(isinstance(s, Shift) for s in shifts)
    assert [s.day.day for s in shifts] == [13, 14, 15, 16]
    assert [s.hours for s in shifts] == [11.5, 11, 12, 12.25]
    assert {s.event for s in shifts} == {"Hermes Private Sale"}


def test_parse_multiple_lines_reports_bad_line():
    results = parse_shifts("13/8 8.30am - 8pm Gig\nnonsense line", today=TODAY)
    assert isinstance(results[0][1], Shift)
    assert isinstance(results[1][1], ParseError)


@pytest.mark.parametrize(
    "args, expected",
    [
        ([], None),
        (["2026-08"], "2026-08"),
        (["aug"], "2026-08"),
        (["August"], "2026-08"),
        (["8"], "2026-08"),
        (["july", "2025"], "2025-07"),
        (["this", "month"], "2026-08"),
        (["last", "month"], "2026-07"),
    ],
)
def test_parse_month(args, expected):
    assert parse_month(args, today=TODAY) == expected


def test_parse_month_rejects_nonsense():
    with pytest.raises(ParseError):
        parse_month(["banana"], today=TODAY)


def test_month_summaries(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    for day, pay in [(date(2026, 8, 1), "100"), (date(2026, 8, 2), "50"), (date(2026, 7, 3), "70")]:
        storage.add_shift(
            1, day, time(9, 0), time(17, 0), "Gig",
            Decimal("0"), False, Decimal("8"), Decimal(pay), "SGD",
        )
    summaries = storage.month_summaries(1)
    assert [(s.month, s.shifts, s.pay) for s in summaries] == [
        ("2026-08", 2, Decimal("150.0")),
        ("2026-07", 1, Decimal("70.0")),
    ]


def test_totals_drop_after_delete(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    ids = [
        storage.add_shift(
            1, date(2026, 8, day), time(9, 0), time(17, 0), "Gig",
            Decimal("0"), False, Decimal("8"), Decimal("100"), "SGD",
        )
        for day in (1, 2, 3)
    ]
    assert storage.month_summaries(1)[0].pay == Decimal("300.0")

    assert storage.delete_shift(1, ids[0]) is True
    assert storage.month_summaries(1)[0].pay == Decimal("200.0")
    assert len(storage.list_shifts(1, month="2026-08")) == 2

    assert storage.delete_shifts(1, month="2026-08") == 2
    assert storage.month_summaries(1) == []
    assert storage.list_shifts(1) == []


def test_get_shift_returns_none_for_other_users(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    shift_id = storage.add_shift(
        1, date(2026, 8, 1), time(9, 0), time(17, 0), "Gig",
        Decimal("0"), False, Decimal("8"), Decimal("100"), "SGD",
    )
    assert storage.get_shift(1, shift_id) is not None
    assert storage.get_shift(2, shift_id) is None
    assert storage.delete_shift(2, shift_id) is False


def test_storage_roundtrip(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    config = RateConfig(default_rate=Decimal("20"), event_rates={"gig": Decimal("30")})
    storage.save_config(1, config)
    assert storage.get_config(1).rate_for("Gig") == Decimal("30")

    shift_id = storage.add_shift(
        1, date(2026, 8, 12), time(18, 0), time(23, 30), "Gig",
        Decimal("1"), False, Decimal("4.5"), Decimal("135.00"), "SGD",
    )
    records = storage.list_shifts(1, month="2026-08")
    assert [r.id for r in records] == [shift_id]
    assert records[0].pay == Decimal("135.00")
    assert records[0].break_hours == Decimal("1")
    assert records[0].break_paid is False
    assert storage.delete_shift(1, shift_id) is True
    assert storage.list_shifts(1) == []
