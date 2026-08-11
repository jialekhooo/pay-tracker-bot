from dataclasses import replace
from datetime import date, datetime, time
from decimal import Decimal

import pytest

from paybot.bot import SECTIONS, _edit_record, commands_text, parse_edit, parse_month
from paybot.calendar_export import google_link, to_ics
from paybot.feed import feed_body, issue_token
from paybot.parsing import ParseError, Shift, parse_shift, parse_shifts
from paybot.pay import RateConfig, calculate_pay
from paybot.reminders import due, format_offset, parse_offset
from paybot.schedule import find_clashes
from paybot.storage import Reminder, ShiftRecord, Storage

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


def test_event_name_first_with_inline_rate():
    shift = parse_shift("Wedding gig 12/8 6pm-11.30pm 25/h", today=date(2026, 8, 1))
    assert shift.day == date(2026, 8, 12)
    assert (shift.start, shift.end) == (time(18, 0), time(23, 30))
    assert shift.event == "Wedding gig"
    assert shift.rate_override == Decimal("25")
    assert shift.hours == 5.5


def test_event_name_first_variants():
    shift = parse_shift("Roadshow today 9am to 5pm", today=date(2026, 8, 1))
    assert (shift.day, shift.event) == (date(2026, 8, 1), "Roadshow")
    assert shift.hours == 8

    shift = parse_shift(
        "Hermes Private Sale 13/8 8.30am - 8pm 1h unpaid break", today=date(2026, 8, 1)
    )
    assert shift.event == "Hermes Private Sale"
    assert shift.hours == 10.5


def test_location_after_at_sign():
    shift = parse_shift(
        "Wedding gig 12/8 6pm-11.30pm 25/h @ Marina Bay Sands", today=TODAY
    )
    assert shift.event == "Wedding gig"
    assert shift.location == "Marina Bay Sands"
    assert shift.rate_override == Decimal("25")


def test_location_after_at_word_and_without_one():
    shift = parse_shift("13/8 9am-6pm Roadshow at ION Orchard", today=TODAY)
    assert (shift.event, shift.location) == ("Roadshow", "ION Orchard")

    shift = parse_shift("13/8 9am-6pm Roadshow", today=TODAY)
    assert shift.location == ""


@pytest.mark.parametrize(
    "text, location, rate",
    [
        ("Hermes 13/8 9am-8pm @ MBS 15/h", "MBS", Decimal("15")),
        ("Hermes 13/8 9am-8pm @ MBS SGD 15/h", "MBS", Decimal("15")),
        ("Hermes 13/8 9am-8pm @ MBS $15 per hour", "MBS", Decimal("15")),
        ("Hermes @ MBS 13/8 9am-8pm", "MBS", None),
        ("Hermes @ Level 3 Takashimaya 13/8 9am-8pm 15/h", "Level 3 Takashimaya", Decimal("15")),
        ("Hermes 13/8 9am-8pm @313 Somerset", "313 Somerset", None),
        ("Hermes 13/8 9am-8pm @ MBS, Level 2", "MBS, Level 2", None),
    ],
)
def test_location_is_read_wherever_the_at_sign_appears(text, location, rate):
    shift = parse_shift(text, today=TODAY)
    assert shift.event == "Hermes"
    assert shift.location == location
    assert shift.rate_override == rate
    assert shift.hours == 11


def test_location_is_stored_and_returned(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    shift_id = storage.add_shift(
        1, date(2026, 8, 12), time(9, 0), time(17, 0), "Gig",
        Decimal("0"), False, Decimal("8"), Decimal("100"), "SGD", location="MBS",
    )
    assert storage.get_shift(1, shift_id).location == "MBS"


def test_ics_has_one_event_per_shift_with_escaped_text():
    record = _record(7, date(2026, 8, 12), time(18, 0), time(23, 30), "Wedding, gig")
    ics = to_ics([record], now=datetime(2026, 8, 11, 9, 0))
    assert ics.startswith("BEGIN:VCALENDAR\r\n")
    assert ics.count("BEGIN:VEVENT") == 1
    assert "DTSTART:20260812T180000" in ics
    assert "DTEND:20260812T233000" in ics
    assert "SUMMARY:Wedding\\, gig" in ics
    assert ics.endswith("END:VCALENDAR\r\n")


def test_ics_rolls_an_overnight_shift_into_the_next_day():
    record = _record(8, date(2026, 8, 12), time(22, 0), time(2, 0))
    assert "DTEND:20260813T020000" in to_ics([record])


def test_google_link_uses_utc_and_includes_location():
    record = _record(9, date(2026, 8, 12), time(18, 0), time(23, 30))
    record = replace(record, location="Marina Bay Sands")
    link = google_link(record, 480)
    assert "dates=20260812T100000Z%2F20260812T153000Z" in link
    assert "text=Gig%20%40%20Marina%20Bay%20Sands" in link
    assert "location=Marina%20Bay%20Sands" in link


def test_feed_token_is_stable_until_rotated(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    token = issue_token(storage, 1)
    assert issue_token(storage, 1) == token
    assert storage.user_for_feed_token(token) == 1

    rotated = issue_token(storage, 1, refresh=True)
    assert rotated != token
    assert storage.user_for_feed_token(token) is None
    assert storage.user_for_feed_token(rotated) == 1


def test_feed_body_covers_the_owner_only(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    today = date(2026, 8, 12)
    storage.add_shift(
        1, today, time(9, 0), time(17, 0), "Mine",
        Decimal("0"), False, Decimal("8"), Decimal("100"), "SGD",
    )
    storage.add_shift(
        2, today, time(9, 0), time(17, 0), "Theirs",
        Decimal("0"), False, Decimal("8"), Decimal("100"), "SGD",
    )
    body = feed_body(storage, issue_token(storage, 1), today=today)
    assert "SUMMARY:Mine" in body
    assert "Theirs" not in body
    assert feed_body(storage, "not-a-token", today=today) is None


def _sale_storage(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    for day, event in (
        (date(2026, 8, 13), "Hermes Private Sale"),
        (date(2026, 8, 14), "hermes private sale"),
        (date(2026, 8, 15), "Wedding gig"),
    ):
        storage.add_shift(
            1, day, time(9, 0), time(17, 0), event,
            Decimal("0"), False, Decimal("8"), Decimal("120"), "SGD",
        )
    return storage


def test_find_shifts_matches_event_name_ignoring_case(tmp_path):
    storage = _sale_storage(tmp_path)
    assert len(storage.find_shifts(1, "Hermes Private Sale")) == 2
    assert len(storage.find_shifts(1, "hermes")) == 2
    assert storage.find_shifts(1, "Gala dinner") == []
    assert storage.find_shifts(2, "Hermes Private Sale") == []


def test_update_shift_writes_only_named_columns(tmp_path):
    storage = _sale_storage(tmp_path)
    shift = storage.list_shifts(1)[0]
    assert storage.update_shift(1, shift.id, location="MBS") is True
    assert storage.get_shift(1, shift.id).location == "MBS"
    assert storage.update_shift(2, shift.id, location="Theirs") is False
    with pytest.raises(ValueError):
        storage.update_shift(1, shift.id, currency="USD")


def test_parse_edit_reads_field_target_and_value():
    assert parse_edit("location Hermes Private Sale @ MBS") == (
        "location", "Hermes Private Sale", "MBS",
    )
    assert parse_edit("location Wedding gig at Marina Bay Sands") == (
        "location", "Wedding gig", "Marina Bay Sands",
    )
    assert parse_edit("rate Hermes Private Sale 18") == (
        "rate", "Hermes Private Sale", "18",
    )
    assert parse_edit("rate #12 to $20/h") == ("rate", "#12", "20")
    assert parse_edit("name Hermes Private Sale = Hermes PS") == (
        "name", "Hermes Private Sale", "Hermes PS",
    )
    assert parse_edit("time Hermes Private Sale 9am-8pm") == (
        "time", "Hermes Private Sale", "9am-8pm",
    )
    assert parse_edit("location Hermes Private Sale") is None
    assert parse_edit("colour Hermes Private Sale = red") is None


def test_edit_record_recalculates_pay_for_rate_and_time(tmp_path):
    storage = _sale_storage(tmp_path)
    config = storage.get_config(1)
    record = storage.find_shifts(1, "Wedding gig")[0]

    assert _edit_record(record, "location", "MBS", config) == {"location": "MBS"}
    assert _edit_record(record, "name", "Gala", config) == {"event": "Gala"}
    assert _edit_record(record, "rate", "20", config)["pay"] == "160.00"

    retimed = _edit_record(record, "time", "9am-8pm", config)
    assert retimed["start_time"] == "09:00"
    assert retimed["end_time"] == "20:00"
    assert retimed["hours"] == "11"
    assert retimed["pay"] == "165.00"


def test_every_command_is_listed_and_unique():
    listing = commands_text()
    seen = set()
    for _, section in SECTIONS:
        for command in section:
            assert command.usage.startswith(f"/{command.name}")
            assert command.usage in listing
            assert len(command.summary) <= 60  # Telegram's menu limit is 256
            for alias in command.names:
                assert alias not in seen
                seen.add(alias)
    assert {"commands", "help", "total", "reminders"} <= seen


def _reminder(send_at=time(20, 0), offset=480, enabled=True, last_sent_on=None):
    return Reminder(
        user_id=1,
        chat_id=99,
        send_at=send_at,
        utc_offset_minutes=offset,
        enabled=enabled,
        last_sent_on=last_sent_on,
    )


def test_reminder_is_due_once_per_day_in_local_time():
    # 12:30 UTC is 20:30 in UTC+8, past the 20:00 send time.
    now = datetime(2026, 8, 12, 12, 30)
    assert due(_reminder(), now) == date(2026, 8, 13)
    assert due(_reminder(last_sent_on=date(2026, 8, 12)), now) is None
    assert due(_reminder(enabled=False), now) is None
    # 10:00 UTC is 18:00 locally — too early.
    assert due(_reminder(), datetime(2026, 8, 12, 10, 0)) is None


def test_parse_and_format_offset():
    assert parse_offset("+8") == 480
    assert parse_offset("-5:30") == -330
    assert parse_offset("5.5") == 330
    assert format_offset(480) == "UTC+8"
    assert format_offset(-330) == "UTC-5:30"
    with pytest.raises(ValueError):
        parse_offset("+20")


def test_reminder_settings_roundtrip(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    assert storage.get_reminder(1) is None
    storage.save_reminder(1, 99, time(19, 30), 480, True)
    saved = storage.get_reminder(1)
    assert (saved.chat_id, saved.send_at, saved.enabled) == (99, time(19, 30), True)
    assert [r.user_id for r in storage.enabled_reminders()] == [1]

    storage.mark_reminder_sent(1, date(2026, 8, 12))
    assert storage.get_reminder(1).last_sent_on == date(2026, 8, 12)

    storage.save_reminder(1, 99, time(19, 30), 480, False)
    assert storage.enabled_reminders() == []


def _record(shift_id, day, start, end, event="Gig"):
    return ShiftRecord(
        id=shift_id, day=day, start=start, end=end, event=event, location="",
        break_hours=Decimal("0"), break_paid=False, hours=Decimal("8"),
        pay=Decimal("100"), currency="SGD",
    )


def test_find_clashes_flags_overlapping_shifts():
    booked = [
        _record(1, date(2026, 8, 12), time(9, 0), time(17, 0), "Roadshow"),
        _record(2, date(2026, 8, 13), time(9, 0), time(17, 0), "Wedding"),
    ]
    clashes = find_clashes(booked, date(2026, 8, 12), time(16, 0), time(20, 0))
    assert [c.id for c in clashes] == [1]

    assert find_clashes(booked, date(2026, 8, 12), time(17, 0), time(22, 0)) == []
    assert find_clashes(booked, date(2026, 8, 14), time(9, 0), time(17, 0)) == []


def test_find_clashes_handles_overnight_shifts():
    booked = [_record(1, date(2026, 8, 12), time(22, 0), time(2, 0), "Night gig")]
    clashes = find_clashes(booked, date(2026, 8, 13), time(1, 0), time(5, 0))
    assert [c.id for c in clashes] == [1]
    assert find_clashes(booked, date(2026, 8, 13), time(3, 0), time(5, 0)) == []


def test_shifts_between_returns_range_in_order(tmp_path):
    storage = Storage(tmp_path / "test.sqlite3")
    for day in (10, 12, 20):
        storage.add_shift(
            1, date(2026, 8, day), time(9, 0), time(17, 0), "Gig",
            Decimal("0"), False, Decimal("8"), Decimal("100"), "SGD",
        )
    records = storage.shifts_between(1, date(2026, 8, 11), date(2026, 8, 19))
    assert [r.day.day for r in records] == [12]


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
