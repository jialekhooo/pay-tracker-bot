"""Ported from ios/Tests/HowMuchCoreTests/JobMessageTests.swift, plus how the bot uses the parser."""
import asyncio
from datetime import date, time
from decimal import Decimal

import pytest

from paybot import bot
from paybot.job_message import job_shifts, parse_job_message, parse_message
from paybot.parsing import ParseError, Shift, parse_shifts
from tests.test_howmuch_link import Server, harness

TODAY = date(2026, 11, 5)


def parse(text, today=TODAY):
    return parse_job_message(text, today)


def clock(minute):
    return f"{minute // 60:02d}:{minute % 60:02d}"


def slots(job):
    return [f"{d.day} {clock(d.start_minute)}-{clock(d.end_minute)}" for d in job.dates]


def test_whatsapp_offer_with_venue_address_and_date_ranges():
    job = parse(
        "ni hao! you free for this?\n\n"
        "Location: The Singapore EDITION Hotel\n"
        "Address: 38 Cuscaden Rd, Singapore 249731\n\n"
        "12th Nov 1200-2100hrs\n13-14th Nov 0800-2000hrs\n15th Nov 0900-2000hrs"
    )
    assert slots(job) == ["2026-11-12 12:00-21:00", "2026-11-13 08:00-20:00",
                          "2026-11-14 08:00-20:00", "2026-11-15 09:00-20:00"]
    assert job.location == "The Singapore EDITION Hotel, 38 Cuscaden Rd, Singapore 249731"
    assert job.name == "The Singapore EDITION Hotel"
    assert job.rate is None and job.fixed_pay is None
    assert job.skipped == []


def test_telegram_bot_style_lines():
    # 12 August is months behind 5 November, so it means next year.
    assert slots(parse("Wedding gig 12/8 6pm-11.30pm 25/h @ Marina Bay Sands")) == ["2027-08-12 18:00-23:30"]
    wedding = parse("Wedding gig 12/12 6pm-11.30pm 25/h @ Marina Bay Sands")
    assert slots(wedding) == ["2026-12-12 18:00-23:30"]
    assert (wedding.event, wedding.location, wedding.rate) == ("Wedding gig", "Marina Bay Sands", 25)

    iso = parse("2026-08-12 18:00 23:30 Wedding gig")
    assert slots(iso) == ["2026-08-12 18:00-23:30"]
    assert iso.event == "Wedding gig"

    roadshow = parse("Roadshow today 9am to 5pm")
    assert slots(roadshow) == ["2026-11-05 09:00-17:00"]
    assert roadshow.event == "Roadshow"

    super_return = parse("28/11 0700 - 1900 SuperReturn @ MBS 20/h")
    assert slots(super_return) == ["2026-11-28 07:00-19:00"]
    assert (super_return.event, super_return.location, super_return.rate) == ("SuperReturn", "MBS", 20)


def test_labelled_fields_times_on_their_own_line_and_pay():
    job = parse(
        "Event: Hermes Private Sale\nVenue: Marina Bay Sands Expo\nDates: 13, 14 & 16 Nov\n"
        "Time: 9am - 6pm\nPay: $15/hr\nBreak: 1hr\nContact: Jia Le 9123 4567\nAttire: all black"
    )
    assert job.event == "Hermes Private Sale"
    assert job.location == "Marina Bay Sands Expo"
    assert slots(job) == ["2026-11-13 09:00-18:00", "2026-11-14 09:00-18:00", "2026-11-16 09:00-18:00"]
    assert job.rate == 15
    assert job.break_minutes == 60
    assert job.skipped == []


@pytest.mark.parametrize("text, expected", [
    ("Nov 20-22 10pm-2am", ["2026-11-20 22:00-02:00", "2026-11-21 22:00-02:00", "2026-11-22 22:00-02:00"]),
    ("5 Jan 9-6", ["2027-01-05 09:00-18:00"]),
    ("30 Nov - 2 Dec 0800-1700", ["2026-11-30 08:00-17:00", "2026-12-01 08:00-17:00", "2026-12-02 08:00-17:00"]),
    ("Wed 12 Nov (Wed) 11-2pm", ["2026-11-12 11:00-14:00"]),
])
def test_month_first_ranges_overnight_and_next_year(text, expected):
    assert slots(parse(text)) == expected


def test_per_day_and_lump_sum_pay():
    daily = parse("12 Nov 9am-6pm\n$150/day")
    assert daily.fixed_pay == 150 and daily.rate is None

    lump = parse("SGD 500 lump sum\n12-15 Nov 9am-6pm")
    assert len(lump.dates) == 4
    assert lump.fixed_pay == 125
    assert lump.currency == "SGD"
    assert lump.lump_sum == 500


def test_unreadable_lines_are_reported_not_guessed():
    job = parse("Hello!\nNeed 3 pax\nAround 4 hours")
    assert job.dates == []
    assert job.skipped == ["Need 3 pax", "Around 4 hours"]


def test_dates_without_any_time_are_flagged():
    job = parse("12 Nov and 13 Nov")
    assert job.dates == []
    assert job.no_time == [date(2026, 11, 12), date(2026, 11, 13)]


def test_each_day_can_have_its_own_time_on_a_later_line():
    job = parse(
        "*LAST 3 SLOTS*\nEvent crew wanted for AI pop up | 19, 21, 22 Nov | New Bahru\n$$13/h\n\n"
        "Dates and time\n19th: 3.30pm - 6pm (Briefing + private showcase)\n21,22nd: 9am - 6pm\n\n"
        "Attire: Plain black tshirt, black pants/ jeans (non-faded, non-ripped), plain black or white sneakers\n\n"
        "Scope: Help to greet people and explain the activities within the space\n\n"
        "Those available please PM me"
    )
    assert slots(job) == ["2026-11-19 15:30-18:00", "2026-11-21 09:00-18:00", "2026-11-22 09:00-18:00"]
    assert (job.rate, job.location, job.event) == (13, "New Bahru", "AI pop up")


def test_day_times_accept_ranges_and_ampersands():
    job = parse("Roadshow 12-14 Nov @ VivoCity\n12 & 13: 10am-6pm\n14th: 2pm-10pm")
    assert slots(job) == ["2026-11-12 10:00-18:00", "2026-11-13 10:00-18:00", "2026-11-14 14:00-22:00"]
    # A clock time at the start of a line is not mistaken for a day.
    assert slots(parse("Roadshow 12 Nov\n10:00am - 6pm")) == ["2026-11-12 10:00-18:00"]


def test_ordinals_in_a_day_list_are_not_a_range():
    job = parse("Roadshow 19, 20, 21 Nov 8am-4pm\n19th, 21st: 9am-6pm")
    assert slots(job) == ["2026-11-19 09:00-18:00", "2026-11-20 08:00-16:00", "2026-11-21 09:00-18:00"]


def test_heading_line_names_the_event_when_no_date_line_does():
    job = parse("Nike Pop-up\n19 Nov 3.30pm-6pm\n$15/h")
    assert job.event == "Nike Pop-up"
    assert job.rate == 15
    assert slots(job) == ["2026-11-19 15:30-18:00"]
    # Recruiting words in front of the heading are dropped.
    assert parse("Crew wanted for Nike Pop-up\n19th Nov: 3.30pm - 6pm\n21,22nd Nov: 9am - 6pm").event == "Nike Pop-up"
    # A name on the date line still wins over the heading.
    assert parse("Weekend gigs\nWedding gig 12/11 6pm-11pm").event == "Wedding gig"
    # An event label wins too.
    assert parse("Weekend gigs\nEvent: Hermes Sale\n12 Nov 9am-6pm").event == "Hermes Sale"


@pytest.mark.parametrize("text", [
    "Hi all\n12 Nov 9am-6pm",
    "Anyone free this weekend?\n12 Nov 9am-6pm",
    "Looking for promoters\n12 Nov 9am-6pm",
    "12 Nov 9am-6pm\nDates and time\nThose available please PM me",
])
def test_greetings_questions_and_later_plain_lines_are_not_event_names(text):
    assert parse(text).event is None


def test_heading_venues_and_pinned_locations_are_read():
    today = date(2026, 11, 7)
    roadshow = parse("Roadshow at VivoCity\n15 Nov (Sat) 10am-10pm\n$12/hr\n1hr break", today)
    assert (roadshow.event, roadshow.location, roadshow.break_minutes) == ("Roadshow", "VivoCity", 60)
    assert roadshow.skipped == []
    assert parse("Sampling @ NEX\n28 Nov, 11am to 9pm\n$11.50 per hour", today).location == "NEX"
    pinned = parse("Crew needed\n📍 Marina Bay Sands\n📅 20-21 Nov\n⏰ 9am - 6pm\n💰 $13/h", today)
    assert (pinned.location, len(pinned.dates), pinned.rate) == ("Marina Bay Sands", 2, 13)


@pytest.mark.parametrize("text, expected", [
    ("Roadshow\nSat 21 & Sun 22 Nov, 10am-7pm", ["2026-11-21 10:00-19:00", "2026-11-22 10:00-19:00"]),
    ("Roadshow\n21 (Sat), 22 (Sun) & 23 (Mon) Nov 10am-7pm",
     ["2026-11-21 10:00-19:00", "2026-11-22 10:00-19:00", "2026-11-23 10:00-19:00"]),
    ("Roadshow\nFri 20 - Sun 22 Nov 9am-6pm",
     ["2026-11-20 09:00-18:00", "2026-11-21 09:00-18:00", "2026-11-22 09:00-18:00"]),
    # A weekday on its own still means the next one.
    ("Roadshow\nSat 10am-7pm", ["2026-11-07 10:00-19:00"]),
])
def test_weekdays_between_days_keep_every_date(text, expected):
    assert slots(parse(text)) == expected


def test_emoji_are_not_part_of_the_name_or_venue():
    job = parse("Roadshow at VivoCity 🎉\n21 Nov 10am-7pm")
    assert (job.event, job.location) == ("Roadshow", "VivoCity")
    pinned = parse("🎪 Nike Pop-up ✨\n📍 Jewel Changi 🛫\n21 Nov 10am-7pm")
    assert (pinned.event, pinned.location) == ("Nike Pop-up", "Jewel Changi")
    assert parse("Location: Suntec City 🏢\n21 Nov 10am-7pm").location == "Suntec City"


def test_event_name_after_a_greeting_line():
    job = parse(
        "Hi all! Promoter needed 🙌\nRoadshow at VivoCity\n📅 Sat 21 Nov\n⏰ 10am - 7pm (1h break)\n💰 $14/hr"
    )
    assert (job.event, job.location) == ("Roadshow", "VivoCity")
    assert slots(job) == ["2026-11-21 10:00-19:00"]
    assert (job.rate, job.break_minutes) == (14, 60)
    # A recruiting line on its own isn't the event; the heading after it is.
    assert parse("Promoters needed\nSamsung Galaxy launch\n21 Nov 10am-7pm").event == "Samsung Galaxy launch"
    # Headings only count before the details start.
    assert parse("21 Nov 10am-7pm\nPlease reply soon").event is None


def test_a_name_after_a_weekday_keeps_its_letters():
    job = parse("Sat 21 Nov 10am-7pm Roadshow @ VivoCity")
    assert (job.event, job.location) == ("Roadshow", "VivoCity")


def test_paid_and_unpaid_breaks_and_bare_flat_pay():
    unpaid = parse("Gig\n21 Nov 10am-7pm\n1h unpaid break")
    assert (unpaid.break_minutes, unpaid.break_paid) == (60, False)
    assert parse("Gig\n21 Nov 10am-7pm\nBreak: 30 mins paid").break_paid is True
    assert parse("Gig\n21 Nov 10am-7pm\n200 flat").fixed_pay == 200
    assert parse("Gig\n21 Nov 10am-7pm\nTotal 3 days").fixed_pay is None


NOV_9 = date(2026, 11, 9)


def shifts_of(results):
    assert all(isinstance(result, Shift) for _, result in results), results
    return [result for _, result in results]


def test_forwarded_examples():
    [emoji] = shifts_of(parse_message("Roadshow 21/11 10am-7pm 14/h @ VivoCity 🎉", NOV_9))
    assert (emoji.event, emoji.location, emoji.day) == ("Roadshow", "VivoCity", date(2026, 11, 21))

    both = shifts_of(parse_message("Roadshow Sat 21 & Sun 22 Nov 10am-7pm", NOV_9))
    assert [s.day for s in both] == [date(2026, 11, 21), date(2026, 11, 22)]
    assert {s.event for s in both} == {"Roadshow"}

    [post] = shifts_of(parse_message("Hi all! Promoter needed\nRoadshow at VivoCity\nSat 21 Nov 10am-7pm $14/hr", NOV_9))
    assert (post.event, post.location, post.day, post.start, post.end) == (
        "Roadshow", "VivoCity", date(2026, 11, 21), time(10), time(19))
    assert post.rate_override == 14 and not post.pay_is_fixed


@pytest.mark.parametrize("text", [
    "Wedding gig 12/8 6pm-11.30pm 25/h @ Marina Bay Sands",
    "2026-08-12 18:00 23:30 Wedding gig 25/h",
    "Roadshow today 9am to 5pm 1h unpaid break",
    "Wedding gig 12/8 6pm-11.30pm $200 flat",
    "Sunday brunch 12/8 9am-5pm",
    "13/8 8.30am - 8pm 15/h Hermes Private Sale\n14/8 8.30am - 8pm Hermes Private Sale\n15/8 9am-5pm Setup",
    "not a shift",
    "Gig A 13/8 9am-5pm\nnonsense\nGig B 14/8 9am-5pm",
])
def test_one_line_commands_read_exactly_as_before(text):
    before = [(line, str(r) if isinstance(r, ParseError) else r) for line, r in parse_shifts(text, TODAY)]
    after = [(line, str(r) if isinstance(r, ParseError) else r) for line, r in parse_message(text, TODAY)]
    assert after == before


def test_a_post_with_no_dates_gets_one_reply_not_one_per_line():
    [(_, error)] = parse_message("Hello\nAnyone keen\nPM me", NOV_9)
    assert isinstance(error, ParseError)


def test_a_date_with_no_name_or_time_is_explained():
    [(day, error)] = parse_message("Hi all\n21 Nov 10am-7pm", NOV_9)
    assert day == "21 Nov" and "event name" in str(error)
    results = parse_message("Roadshow\n21 Nov 10am-7pm\n22 Nov and Nothing", NOV_9)
    assert any(isinstance(r, Shift) for _, r in results)


def test_lump_sum_shares_add_up_exactly():
    job = parse("Gig\n12-14 Nov 9am-6pm\n$100 lump sum")
    pay = [shift.rate_override for _, shift in job_shifts(job)]
    assert pay == [Decimal("33.33"), Decimal("33.33"), Decimal("33.34")]
    assert sum(pay) == 100


def test_break_uses_the_default_paid_setting_unless_the_post_says():
    job = parse("Gig\n21 Nov 10am-7pm\n1h break")
    [(_, shift)] = job_shifts(job, default_break_paid=True)
    assert shift.break_specified and shift.rest.paid and shift.rest.hours == 1


POST = "Hi all! Promoter needed 🙌\nRoadshow at VivoCity\n📅 Sat 21 & Sun 22 Nov\n⏰ 10am - 7pm\n💰 $14/hr"


def test_linked_chat_posts_a_forwarded_job_to_the_app(tmp_path, monkeypatch):
    monkeypatch.setattr(bot, "_today", lambda *_: NOV_9)
    server = Server()
    server.linked.add(77)
    update, context, replies = harness(tmp_path, server, POST)
    asyncio.run(bot.log_shift(update, context))
    added = [body for path, _, body in server.requests if path == "/v1/bot/shifts"]
    assert len(added) == 1
    assert [(s["event"], s["location"], s["day"], s["rate"]) for s in added[0]["shifts"]] == [
        ("Roadshow", "VivoCity", "2026-11-21", "14"),
        ("Roadshow", "VivoCity", "2026-11-22", "14"),
    ]
    assert "Added 2 shifts" in replies[-1]


def test_unlinked_chat_saves_a_forwarded_job_in_the_bot(tmp_path, monkeypatch):
    monkeypatch.setattr(bot, "_today", lambda *_: NOV_9)
    update, context, replies = harness(tmp_path, Server(), POST)
    asyncio.run(bot.log_shift(update, context))
    records = bot._storage(context).shifts_between(77, date(2026, 11, 1), date(2026, 11, 30))
    assert sorted((r.day, r.event, r.location) for r in records) == [
        (date(2026, 11, 21), "Roadshow", "VivoCity"),
        (date(2026, 11, 22), "Roadshow", "VivoCity"),
    ]
    assert "Logged 2 shifts" in replies[-1]


def test_bare_evening_range_stays_overnight():
    job = parse_job_message("Event: Bar duty\nDate: 15/11\nTime: 6-2\nRate: $15/h", TODAY)
    assert slots(job) == ["2026-11-15 18:00-02:00"]
    daytime = parse_job_message("Event: Promo\nDate: 15/11\nTime: 9-5\nRate: $15/h", TODAY)
    assert slots(daytime) == ["2026-11-15 09:00-17:00"]


def test_bare_morning_range_ending_at_noon_stays_in_the_morning():
    assert slots(parse("Event: Setup\nDate: 15/11\nTime: 6-12\nRate: $15/h")) == ["2026-11-15 06:00-12:00"]


def test_job_brief_is_read_and_sent_on_to_the_app():
    from paybot.howmuch_link import shift_payload
    job = parse("Roadshow 15 Nov 6pm-11pm\nCall time: 5.30\nAttire: All black\nPIC: Sarah\nHP: 9123 4567")
    assert (job.call_minute, job.dress_code, job.contact) == (17 * 60 + 30, "All black", "Sarah 9123 4567")
    assert parse("Setup 15 Nov 9am-6pm\nReporting time: 8.30am").call_minute == 8 * 60 + 30
    assert parse("Setup 15 Nov 9am-6pm\nCall time: 30 mins before").call_minute is None
    [(_, shift)] = job_shifts(job)
    payload = shift_payload(shift)
    assert (payload["callMinute"], payload["dressCode"], payload["contact"]) == (1050, "All black", "Sarah 9123 4567")
    assert "dressCode" not in shift_payload(job_shifts(parse("Promo 15 Nov 9am-5pm"))[0][1])
