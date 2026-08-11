from datetime import date, time
from decimal import Decimal

import pytest

from paybot.parsing import ParseError, parse_shift
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


def test_storage_roundtrip(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    config = RateConfig(default_rate=Decimal("20"), event_rates={"gig": Decimal("30")})
    storage.save_config(1, config)
    assert storage.get_config(1).rate_for("Gig") == Decimal("30")

    shift_id = storage.add_shift(
        1, date(2026, 8, 12), time(18, 0), time(23, 30), "Gig",
        Decimal("5.5"), Decimal("165.00"), "SGD",
    )
    records = storage.list_shifts(1, month="2026-08")
    assert [r.id for r in records] == [shift_id]
    assert records[0].pay == Decimal("165.00")
    assert storage.delete_shift(1, shift_id) is True
    assert storage.list_shifts(1) == []
