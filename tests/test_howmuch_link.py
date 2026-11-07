"""The Telegram bot linked to a HowMuch app account."""
import asyncio
import json
from datetime import date, time
from decimal import Decimal
from types import SimpleNamespace

import httpx

from paybot import bot
from paybot.howmuch_link import HowMuchLink, shift_payload
from paybot.parsing import Break, Shift
from paybot.storage import Storage


def test_shift_payload_keeps_only_what_was_written():
    plain = Shift(day=date(2026, 12, 12), start=time(18), end=time(23, 30), event="Wedding gig", location="MBS")
    assert shift_payload(plain) == {"event": "Wedding gig", "location": "MBS", "day": "2026-12-12",
                                    "startMinute": 1080, "endMinute": 1410}
    flat = Shift(day=date(2026, 12, 12), start=time(9), end=time(17), event="Promo", rate_override=Decimal("200"),
                 pay_is_fixed=True, rest=Break(hours=1, paid=False), break_specified=True)
    assert shift_payload(flat)["fixedPay"] == "200" and shift_payload(flat)["breakMinutes"] == 60
    hourly = Shift(day=date(2026, 12, 12), start=time(9), end=time(17), event="Promo", rate_override=Decimal("15"))
    assert shift_payload(hourly)["rate"] == "15" and "fixedPay" not in shift_payload(hourly)


class Server:
    """A stand-in for the HowMuch server."""
    def __init__(self):
        self.requests = []
        self.linked = set()

    def handler(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        self.requests.append((request.url.path, request.headers.get("X-HowMuch-Bot"), body))
        user = body.get("telegramUserId")
        if request.url.path == "/v1/bot/status":
            return httpx.Response(200, json={"linked": user in self.linked, "displayName": "Jia"})
        if request.url.path == "/v1/bot/link":
            if body["code"] != "good-code-123":
                return httpx.Response(404, json={"detail": "That link has expired."})
            self.linked.add(user)
            return httpx.Response(200, json={"linked": True, "displayName": "Jia"})
        if request.url.path == "/v1/bot/shifts":
            return httpx.Response(200, json={"added": [
                {"event": s["event"], "location": s.get("location", ""), "day": s["day"], "startMinute": s["startMinute"],
                 "endMinute": s["endMinute"], "breakMinutes": 0, "pay": 100, "currency": "SGD"} for s in body["shifts"]],
                "clashes": []})
        if request.url.path == "/v1/bot/summary":
            return httpx.Response(200, json={"displayName": "Jia", "owed": [{"currency": "SGD", "amount": 130, "shifts": 2}],
                                             "upcoming": []})
        return httpx.Response(404, json={})


def harness(tmp_path, server, text="", args=None):
    replies = []

    async def reply_text(message, **_):
        replies.append(message)
    link = HowMuchLink("secret-1", "https://howmuch.test", httpx.AsyncClient(transport=httpx.MockTransport(server.handler)))
    application = SimpleNamespace(bot_data={"storage": Storage(tmp_path / "bot.sqlite3"), "howmuch": link})
    update = SimpleNamespace(effective_user=SimpleNamespace(id=77, username="jia"),
                             message=SimpleNamespace(text=text, reply_text=reply_text))
    context = SimpleNamespace(application=application, args=args or [], bot_data=application.bot_data)
    return update, context, replies


def test_start_with_a_code_links_and_shifts_then_go_to_the_app(tmp_path):
    server = Server()
    update, context, replies = harness(tmp_path, server, args=["link-good-code-123"])
    asyncio.run(bot.start(update, context))
    assert "Linked" in replies[-1] and 77 in server.linked
    assert all(secret == "secret-1" for _, secret, _ in server.requests)
    update, context, replies = harness(tmp_path, server, text="Wedding gig 12/12 6pm-11pm @ MBS")
    context.application.bot_data["howmuch"] = HowMuchLink("secret-1", "https://howmuch.test",
                                                          httpx.AsyncClient(transport=httpx.MockTransport(server.handler)))
    asyncio.run(bot.log_shift(update, context))
    assert "Added 1 shift to HowMuch" in replies[-1]
    sent = next(body for path, _, body in server.requests if path == "/v1/bot/shifts")
    assert sent["shifts"][0]["event"] == "Wedding gig" and sent["shifts"][0]["location"] == "MBS"
    # Nothing was stored in the bot's own records.
    assert context.application.bot_data["storage"].list_shifts(77) == []


def test_bad_code_explains_and_stays_unlinked(tmp_path):
    server = Server()
    update, context, replies = harness(tmp_path, server, args=["link-old-code-999"])
    asyncio.run(bot.start(update, context))
    assert "expired" in replies[-1] and not server.linked


def test_owed_reads_the_app_and_bot_only_commands_point_to_the_app(tmp_path):
    server = Server(); server.linked.add(77)
    update, context, replies = harness(tmp_path, server)
    asyncio.run(bot.owed(update, context))
    assert "SGD 130.00" in replies[-1] and "2 shifts" in replies[-1]
    asyncio.run(bot._bot_records_only(bot.total)(update, context))
    assert "linked with the HowMuch app" in replies[-1]


def test_unlinked_chats_keep_using_the_bot_records(tmp_path):
    server = Server()
    update, context, replies = harness(tmp_path, server, text="Wedding gig 12/12 6pm-11pm")
    asyncio.run(bot.log_shift(update, context))
    assert "Logged 1 shift" in replies[-1]
    assert not any(path == "/v1/bot/shifts" for path, _, _ in server.requests)
    assert len(context.application.bot_data["storage"].list_shifts(77)) == 1
