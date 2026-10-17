"""The live throughput relay and the sampled node and quota reads (#102).

`/v1/stats/live` relays mihomo's aggregate throughput (its /traffic stream)
to the browser as Server-Sent Events - same-origin, so the browser never
contacts mihomo - and stores none of it. One relay thread serves every
viewer: it starts with the first and stops after the last, so a panel
nobody is watching reads no stream at all.

`/v1/stats/node-delay` and `/v1/stats/quota` serve what the sampler stored
(app/collector/sampler.py). They read the store only, through the
read-only reader connections; mihomo is never called on a request. Like
every stats read they need no token - which is why the panel must never be
exposed to the WAN: airport node labels and the subscription quota, behind
the controller secret in MetaCubexD, are LAN-readable here.
"""

import asyncio
import json
import threading
import time
from contextlib import suppress
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import StreamingResponse

from app import config
from app.api import routes
from app.mihomo_client.client import TRAFFIC_TIMEOUT_S
from app.store import settings
from app.store import stats as stats_store

router = APIRouter()

RETRY_MS = 5000
FULL_RETRY_MS = 60_000
HEARTBEAT_S = 15
MAX_SUBSCRIBERS = 16
QUEUE_FRAMES = 30
BACKOFF_S = (1, 2, 4, 8, 15)
SSE_HEADERS = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
# what Relay.close() hands every viewer: the stream ends
_CLOSED = None


def _stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Subscription:
    """One viewer's frames, on its event loop. A viewer that falls behind
    loses its OLDEST frame - a live picture wants the newest, and a slow
    client must never grow the panel's memory."""

    def __init__(self, loop):
        self.loop = loop
        self.queue = asyncio.Queue(maxsize=QUEUE_FRAMES)

    def offer(self, frame) -> None:
        if self.queue.full():
            with suppress(asyncio.QueueEmpty):
                self.queue.get_nowait()
        self.queue.put_nowait(frame)


class Relay:
    """One upstream /traffic reader shared by every viewer. CLIENT is the
    mihomo client (its `traffic_frames()`); SLEEP is the stop-aware wait
    between reconnects (a test injects its own)."""

    def __init__(self, client, *, max_subscribers: int = MAX_SUBSCRIBERS,
                 backoff=BACKOFF_S, stamp=_stamp):
        self.client = client
        self.max_subscribers = max_subscribers
        self.backoff = tuple(backoff)
        self.stamp = stamp
        self._lock = threading.Lock()
        self._subs: set[Subscription] = set()
        # set when nobody watches (or on close): wakes a reconnect wait
        self._stop = threading.Event()
        self._closed = False
        self._thread: threading.Thread | None = None
        # the reconnect backoff lives on the relay, not on one thread: a
        # viewer arriving after the last relay exited waits it out too, so
        # churn never turns a down mihomo into a reconnect per viewer
        self._failures = 0
        self._next_attempt = 0.0
        # in memory only, for tests and the curious: is the upstream open
        self.upstream_reads = 0

    def has_room(self) -> bool:
        with self._lock:
            return len(self._subs) < self.max_subscribers

    def subscribe(self, loop) -> Subscription | None:
        """A new viewer, or None at the cap. The first viewer starts the
        relay. One arriving while the relay is still winding down after the
        last viewer KEEPS that thread rather than starting a second: there is
        only ever one relay thread and one upstream stream, however fast
        viewers come and go (the thread decides to exit only under the lock,
        and only when it finds nobody)."""
        with self._lock:
            if self._closed or len(self._subs) >= self.max_subscribers:
                return None
            sub = Subscription(loop)
            self._subs.add(sub)
            self._stop.clear()
            if self._thread is None:
                self._thread = threading.Thread(
                    target=self._run, daemon=True, name="panel-live-relay")
                self._thread.start()
            return sub

    def unsubscribe(self, sub: Subscription) -> None:
        """A viewer left; the last one leaving stops the relay (within one
        upstream frame - it checks after each - or at once while it waits
        to reconnect)."""
        with self._lock:
            self._subs.discard(sub)
            if not self._subs:
                self._stop.set()

    def _idle_exit_pending(self) -> bool:
        """Nobody watching (or closing): the wait can stop and the loop's
        own check decide - without deciding here."""
        with self._lock:
            return self._closed or not self._subs

    def _idle_exit(self) -> bool:
        """The thread's exit decision, under the lock: nobody watching (or
        the app closing) and it clears itself, so the next viewer starts a
        new one."""
        with self._lock:
            if self._closed or not self._subs:
                self._thread = None
                return True
            return False

    def viewers(self) -> int:
        with self._lock:
            return len(self._subs)

    def running(self) -> bool:
        with self._lock:
            return (self._thread is not None and self._thread.is_alive()
                    and bool(self._subs))

    def close(self) -> None:
        """App shutdown: stop reading, and end every viewer's stream rather
        than leave it waiting on frames that will never come."""
        with self._lock:
            self._closed = True
            self._stop.set()
            thread = self._thread
        self._broadcast(_CLOSED)
        if thread is not None and thread.is_alive():
            # a read returns within its own timeout and a wait at once
            thread.join(timeout=TRAFFIC_TIMEOUT_S + 1)

    def _broadcast(self, frame) -> None:
        with self._lock:
            subs = list(self._subs)
        for sub in subs:
            # a loop that has closed (its viewer is gone) refuses the call
            with suppress(RuntimeError):
                sub.loop.call_soon_threadsafe(sub.offer, frame)

    def _run(self) -> None:
        while not self._idle_exit():
            # wait out the backoff - a viewer leaving wakes the wait, one
            # arriving clears the flag, so re-wait the rest while anyone
            # watches; nobody watching ends it and the loop's check decides
            while not self._idle_exit_pending():
                remaining = self._next_attempt - time.monotonic()
                if remaining <= 0:
                    break
                self._stop.wait(remaining)
            if self._idle_exit():
                return
            try:
                self.upstream_reads += 1
                for frame in self.client.traffic_frames():
                    # every line is a tick, readable or not: the last viewer
                    # leaving is noticed even on a stream of unreadable ones
                    if self._stop.is_set() and self._idle_exit():
                        return
                    if frame is None:
                        continue
                    self._failures = 0
                    up, down = frame
                    self._broadcast({"ts": self.stamp(), "up_bps": up,
                                     "down_bps": down})
            except Exception:
                pass
            # the stream ended or broke: the next attempt backs off
            self._next_attempt = time.monotonic() + self.backoff[
                min(self._failures, len(self.backoff) - 1)]
            self._failures += 1


async def sse_events(relay: Relay, loop, *, heartbeat_s: float = HEARTBEAT_S):
    """The event stream for one viewer. It subscribes INSIDE the generator,
    so a viewer that never reads cannot hold a slot, and unsubscribes in
    `finally` - a dropped connection (the server cancels the generator)
    always frees it."""
    sub = relay.subscribe(loop)
    if sub is None:
        # the cap was reached between the endpoint's check and here: say so
        # once, and ask the browser to wait a minute before trying again
        yield f"retry: {FULL_RETRY_MS}\nevent: full\ndata: {{}}\n\n"
        return
    try:
        yield f"retry: {RETRY_MS}\n\n"
        while True:
            try:
                frame = await asyncio.wait_for(sub.queue.get(), heartbeat_s)
            except TimeoutError:
                yield ": ping\n\n"
                continue
            if frame is _CLOSED:
                return
            yield f"data: {json.dumps(frame, separators=(',', ':'))}\n\n"
    finally:
        relay.unsubscribe(sub)


@router.get("/v1/stats/live", response_class=StreamingResponse, responses={
    200: {"content": {"text/event-stream": {"schema": {"type": "string"}}},
          "description": "An unending text/event-stream (see above)."},
    503: {"description": "Too many live viewers already connected"}})
async def stats_live(request: Request):
    """Gateway-wide throughput, live, as Server-Sent Events. Nothing from
    this stream is stored.

    The stream opens with `retry: 5000` (reconnect after 5 s), then sends
    one event per mihomo /traffic frame (about one a second):

        data: {"ts": "2026-10-16T12:00:00Z", "up_bps": 1200, "down_bps": 56000}

    `up_bps` / `down_bps` are BYTES per second, as mihomo reports them, and
    `ts` is the panel's clock when the frame was relayed. `/health`
    `live_viewers` says how many viewers are connected right now. When no frame has
    arrived for 15 s - mihomo restarting, the stream reconnecting - a
    `: ping` comment keeps the connection open; a viewer shows how long it
    has been since the last `data` event, never a frozen number. One relay
    serves every viewer and reads mihomo only while at least one is
    connected; past 16 concurrent viewers the answer is 503 - or, when the
    16th slot went in the instant between that check and the stream
    starting, a stream of `retry: 60000`, one `event: full` and its end.
    The panel shutting down ends every stream."""
    relay = request.app.state.live_relay
    if not relay.has_room():
        raise HTTPException(status_code=503,
                            detail="too many live viewers - close another one")
    return StreamingResponse(sse_events(relay, asyncio.get_running_loop()),
                             media_type="text/event-stream", headers=SSE_HEADERS)


@router.get("/v1/stats/node-delay")
def stats_node_delay(
        request: Request,
        range_: Annotated[routes.StatsRange, Query(alias="range", description=(
            "The window preset, cut to the retention "
            "(PANEL_NODE_DELAY_DAYS)"))] = settings.DEFAULT_STATS_RANGE,
) -> dict:
    """The delay of each policy group's SELECTED node over a window, from
    the tests mihomo itself ran (sampled every 300 s; the panel never probes
    a node). `24h` and `48h` list the tests (`resolution: "test"`); longer
    presets give one entry per hour and node (`resolution: "hour"`) with the
    mean delay of the tests that answered, their range, how many answered
    (`tests`) and how many failed (`failed`). A failed test is null, never
    0 ms - an hour of nothing but failures has a null delay. `since` is
    where the window really starts: the later of the preset's start and the
    retention, and `truncated` says the preset reached further back than
    anything is kept. `latest` is each group's newest stored test - the
    selection as of its `tested_at`. Node labels are the provider's own,
    stored as given."""
    with routes._stats_reader(request) as conn:
        body = stats_store.read_node_delay(conn, range_, routes._utcnow(),
                                           config.node_delay_days())
    return body


@router.get("/v1/stats/quota")
def stats_quota(request: Request) -> dict:
    """Each proxy provider's subscription quota, as mihomo last read it from
    the provider's `subscription-userinfo` header (sampled hourly):
    `upload`, `download` and `total` in bytes, `expire` as a Unix time, and
    the provider's own `updatedAt`. Nothing else of the provider is kept -
    never its URL or its nodes. mihomo zero-fills a field the provider did
    not send, so a `total` or `expire` of 0 is reported as null (unknown,
    unlimited or no expiry). `state` says what the newest sample found:
    `ok`, `none` (no provider reports a quota), `error` (mihomo did not
    answer - the list is the last good one), `pending` (not sampled yet) or
    `off` (the collector is not running)."""
    sampler = getattr(request.app.state, "sampler", None)
    # the state is published with the write under the stats lock, and this
    # read takes no lock: a sample or purge landing between the two would
    # pair a list with another moment's state - re-read when it moved
    for _ in range(3):
        epoch = sampler.quota_epoch if sampler is not None else 0
        status = dict(sampler.status) if sampler is not None else {}
        with routes._stats_reader(request) as conn:
            providers = stats_store.read_quota(conn)
        if sampler is None or sampler.quota_epoch == epoch:
            break
    return {"providers": providers,
            "state": status.get("quota_state", "off"),
            "sampled_at": status.get("quota_ts")}
