"""The live relay (#102): one upstream /traffic reader that runs only while
someone watches, the SSE stream each viewer gets, and the client's stream
reader against a real chunked HTTP server. Waits are on events and queues,
never on sleeps."""

import asyncio
import json
import queue
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import ClassVar

import pytest
from app.api.live import QUEUE_FRAMES, RETRY_MS, Relay, Subscription, sse_events
from app.mihomo_client.client import MihomoClient

END = object()


class StreamClient:
    """traffic_frames() yields what the test pushes; END ends the stream.
    Every open is its own stream, as every real one is its own connection:
    a push reaches each stream open at the time."""

    def __init__(self):
        self.streams: list[queue.Queue] = []
        self.pending: list = []
        self.lock = threading.Lock()
        self.opens = 0
        self.opened = threading.Event()

    def push(self, item):
        """To every open stream - or, before one opens, to the next one."""
        with self.lock:
            if not self.streams:
                self.pending.append(item)
            for stream in self.streams:
                stream.put(item)

    def traffic_frames(self):
        mine = queue.Queue()
        with self.lock:
            for item in self.pending:
                mine.put(item)
            self.pending = []
            self.streams.append(mine)
            self.opens += 1
        self.opened.set()
        try:
            while True:
                item = mine.get(timeout=5)
                if item is END:
                    return
                yield item
        finally:
            with self.lock:
                self.streams.remove(mine)


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, 10))


# --- the relay -------------------------------------------------------------------

def test_the_relay_reads_only_while_someone_watches():
    client = StreamClient()
    relay = Relay(client, backoff=(0.01,), stamp=lambda: "2026-10-16T12:00:00Z")
    assert client.opens == 0 and not relay.running()

    async def body():
        sub = relay.subscribe(asyncio.get_running_loop())
        client.push((1200, 56000))
        frame = await sub.queue.get()
        assert frame == {"ts": "2026-10-16T12:00:00Z", "up_bps": 1200,
                         "down_bps": 56000}
        thread = relay._thread
        relay.unsubscribe(sub)
        assert relay.viewers() == 0 and not relay.running()
        # the reader notices the stop with the next upstream frame
        client.push((1, 1))
        await asyncio.to_thread(thread.join, 5)
        assert not thread.is_alive() and relay._thread is None

    run(body())
    assert client.opens == 1


def test_one_upstream_serves_every_viewer_and_reconnects_while_watched():
    client = StreamClient()
    relay = Relay(client, backoff=(0.01,))

    async def body():
        loop = asyncio.get_running_loop()
        a, b = relay.subscribe(loop), relay.subscribe(loop)
        client.push((5, 6))
        assert (await a.queue.get())["up_bps"] == 5
        assert (await b.queue.get())["up_bps"] == 5
        assert client.opens == 1
        # mihomo restarts: the stream ends while someone watches - reopen
        client.opened.clear()
        client.push(END)
        await asyncio.to_thread(client.opened.wait, 5)
        assert client.opens == 2
        client.push((7, 8))
        assert (await a.queue.get())["up_bps"] == 7
        thread = relay._thread
        relay.unsubscribe(a)
        relay.unsubscribe(b)
        client.push(END)
        await asyncio.to_thread(thread.join, 5)

    run(body())


def test_a_viewer_arriving_as_the_last_one_leaves_keeps_the_one_relay():
    """However fast viewers come and go there is one relay thread and one
    upstream stream - never a second beside one still winding down."""
    client = StreamClient()
    relay = Relay(client, backoff=(0.01,))

    async def body():
        loop = asyncio.get_running_loop()
        first = relay.subscribe(loop)
        thread = relay._thread
        await asyncio.to_thread(client.opened.wait, 5)
        for _ in range(20):
            relay.unsubscribe(first)
            first = relay.subscribe(loop)
            assert relay._thread is thread
        client.push((9, 9))
        frame = await first.queue.get()
        assert frame["up_bps"] == 9
        assert client.opens == 1
        assert [t.name for t in threading.enumerate()].count("panel-live-relay") == 1
        relay.unsubscribe(first)
        client.push(END)
        await asyncio.to_thread(thread.join, 5)

    run(body())


def test_a_stream_of_unreadable_lines_still_stops_after_the_last_viewer():
    """mihomo drifting its frame shape (renamed fields) must not keep the
    relay - and its upstream - alive after everyone has left."""
    client = StreamClient()
    relay = Relay(client, backoff=(0.01,))

    async def body():
        sub = relay.subscribe(asyncio.get_running_loop())
        await asyncio.to_thread(client.opened.wait, 5)
        thread = relay._thread
        relay.unsubscribe(sub)
        client.push(None)            # an unreadable line: a tick, no frame
        # on that tick - not after a read timeout
        await asyncio.to_thread(thread.join, 1)
        assert not thread.is_alive()
        assert sub.queue.empty()      # nothing was relayed for it

    run(body())


def test_viewers_coming_and_going_never_shorten_the_backoff():
    """mihomo down: the relay backs off, however often viewers churn."""
    import time

    class Down:
        opens = 0

        def traffic_frames(self):
            Down.opens += 1
            raise RuntimeError("connection refused")
            yield  # pragma: no cover

    relay = Relay(Down(), backoff=(0.5,))

    async def body():
        loop = asyncio.get_running_loop()
        # one viewer after another, each gone before the backoff is over -
        # with one held throughout too, a second shape of churn
        until = time.monotonic() + 0.3
        while time.monotonic() < until:
            sub = relay.subscribe(loop)
            await asyncio.sleep(0.01)
            relay.unsubscribe(sub)
            await asyncio.sleep(0.005)
        keep = relay.subscribe(loop)
        for _ in range(20):
            relay.unsubscribe(relay.subscribe(loop))
            await asyncio.sleep(0.005)
        assert Down.opens == 1, Down.opens
        relay.unsubscribe(keep)
        await asyncio.to_thread(relay.close)

    run(body())


def test_past_the_cap_there_is_no_room():
    client = StreamClient()
    relay = Relay(client, max_subscribers=1, backoff=(0.01,))

    async def body():
        loop = asyncio.get_running_loop()
        sub = relay.subscribe(loop)
        assert relay.subscribe(loop) is None and not relay.has_room()
        relay.unsubscribe(sub)
        assert relay.has_room()
        # nobody watching: the relay exits without needing a frame
        client.push(END)
        await asyncio.to_thread(relay.close)

    run(body())


def test_a_slow_viewer_loses_its_oldest_frame_not_the_newest():
    async def body():
        sub = Subscription(asyncio.get_running_loop())
        for i in range(QUEUE_FRAMES + 5):
            sub.offer({"up_bps": i})
        assert sub.queue.qsize() == QUEUE_FRAMES
        assert (await sub.queue.get())["up_bps"] == 5

    run(body())


# --- the event stream ------------------------------------------------------------

def test_the_stream_says_retry_then_data_then_pings_and_frees_its_slot():
    client = StreamClient()
    relay = Relay(client, backoff=(0.01,), stamp=lambda: "2026-10-16T12:00:00Z")

    async def body():
        events = sse_events(relay, asyncio.get_running_loop(), heartbeat_s=0.05)
        assert await events.__anext__() == f"retry: {RETRY_MS}\n\n"
        assert relay.viewers() == 1
        client.push((1, 2))
        data = await events.__anext__()
        assert data.startswith("data: ") and data.endswith("\n\n")
        assert json.loads(data[len("data: "):]) == {
            "ts": "2026-10-16T12:00:00Z", "up_bps": 1, "down_bps": 2}
        # nothing for a while: a comment keeps the connection, no frozen data
        assert await events.__anext__() == ": ping\n\n"
        # a dropped connection closes the generator: the slot is freed
        thread = relay._thread
        await events.aclose()
        assert relay.viewers() == 0
        client.push(END)
        await asyncio.to_thread(thread.join, 5)

    run(body())


def test_a_full_relay_says_so_on_the_stream_and_slows_the_retry():
    relay = Relay(StreamClient(), max_subscribers=0)

    async def body():
        events = sse_events(relay, asyncio.get_running_loop())
        assert await events.__anext__() == (
            "retry: 60000\nevent: full\ndata: {}\n\n")
        with pytest.raises(StopAsyncIteration):
            await events.__anext__()

    run(body())


def test_closing_the_relay_ends_every_open_stream():
    """A shutdown is never held by a viewer waiting on frames."""
    client = StreamClient()
    relay = Relay(client, backoff=(0.01,))

    async def body():
        events = sse_events(relay, asyncio.get_running_loop(), heartbeat_s=5)
        assert (await events.__anext__()).startswith("retry:")
        await asyncio.to_thread(client.opened.wait, 5)
        client.push(END)
        await asyncio.to_thread(relay.close)
        with pytest.raises(StopAsyncIteration):
            await events.__anext__()
        assert relay.viewers() == 0

    run(body())


def test_the_endpoint_answers_503_at_the_cap(client):
    client.app.state.live_relay = Relay(StreamClient(), max_subscribers=0)
    r = client.get("/v1/stats/live")
    assert r.status_code == 503


def test_nothing_from_the_live_feed_is_stored(client, fake_client):
    sconn = client.app.state.stats_conn
    before = sconn.total_changes
    fake_client.traffic = [(10, 20), (30, 40)]
    relay = client.app.state.live_relay

    async def body():
        sub = relay.subscribe(asyncio.get_running_loop())
        got = [await sub.queue.get(), await sub.queue.get()]
        relay.unsubscribe(sub)
        return got

    got = run(body())
    assert [f["down_bps"] for f in got] == [20, 40]
    relay.close()
    assert sconn.total_changes == before
    assert sconn.execute("SELECT COUNT(*) FROM stats_meta WHERE k LIKE '%live%'"
                         ).fetchone()[0] == 0


# --- the client's stream reader --------------------------------------------------

class Upstream(BaseHTTPRequestHandler):
    """A controller that answers the #102 routes like mihomo does."""
    lines: ClassVar[list[bytes]] = []
    seen: ClassVar[list[tuple[str, str]]] = []

    def log_message(self, *args):
        pass

    def do_GET(self):
        Upstream.seen.append((self.path, self.headers.get("Authorization", "")))
        if self.path == "/traffic":
            self.protocol_version = "HTTP/1.1"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for line in Upstream.lines:
                self.wfile.write(f"{len(line):x}\r\n".encode() + line + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            self.close_connection = True
            return
        body = {"/group": {"proxies": [{"name": "Auto", "now": "JP 01"}, "junk"]},
                "/providers/proxies": {"providers": {"p": {"name": "p"}, "x": 3}}
                }.get(self.path)
        if self.path.startswith("/proxies/"):
            body = {"history": [{"time": "2026-10-16T12:00:00Z", "delay": 40}]}
        payload = json.dumps(body).encode() if body is not None else b"{}"
        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


@pytest.fixture()
def upstream():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    Upstream.seen = []
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()
    server.server_close()


def test_the_client_reads_the_chunked_traffic_stream(upstream):
    Upstream.lines = [b'{"up":1200,"down":56000}\n', b"\n", b"not json\n",
                      b'{"up":-1,"down":5}\n', b'{"up":NaN,"down":5}\n',
                      b'{"up":true,"down":5}\n', b'{"up":3,"down":4}\n']
    frames = list(MihomoClient(upstream, "s3cret").traffic_frames())
    # what is not two non-negative numbers is never a frame (never a zero),
    # but still a tick (None) the relay can stop on
    assert frames == [(1200, 56000), None, None, None, None, None, (3, 4)]
    assert Upstream.seen == [("/traffic", "Bearer s3cret")]


def test_the_client_reads_groups_history_and_providers(upstream):
    client = MihomoClient(upstream)
    assert client.groups() == [{"name": "Auto", "now": "JP 01"}]
    assert client.proxy_history("JP 01 🇯🇵/x")[0]["delay"] == 40
    # a node label is one path segment, whatever it contains
    assert Upstream.seen[-1][0] == "/proxies/JP%2001%20%F0%9F%87%AF%F0%9F%87%B5%2Fx"
    assert client.proxy_providers() == {"p": {"name": "p"}}
