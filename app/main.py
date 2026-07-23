"""App factory + uvicorn entrypoint (`uvicorn app.main:app`).

Startup: open/migrate policy.db (fail-STATIC on any store error — the app
still serves, reads answer 503 structurally, provider files are never
touched, and the loud channels fire), then re-sync the provider files from
the store so a restart always converges disk + mihomo to the SSOT.

Deliberately NO CORSMiddleware anywhere: the panel is same-origin only
(DEC-6) and tests assert zero Access-Control-* headers on any response.
"""

import threading
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles

from app import config
from app.api.routes import router
from app.collector.core import Collector, CollectorLoop
from app.mihomo_client.client import MihomoClient
from app.notify import webhook_notify
from app.reconciler.core import Reconciler
from app.store.db import StoreError, open_db
from app.store.policy import desired_state
from app.store.stats import open_stats_db

API_DESCRIPTION = (
    "Dynamic device policy for the Syno Mihomo Gateway. The /v1 surface is "
    "additive-only: fields and endpoints may be added, but a breaking "
    "change (removal, rename, semantics change) requires a NEW version "
    "prefix and explicit owner acknowledgment. Reads are LAN-open; every "
    "mutation requires the PANEL_SECRET bearer token."
)


def create_app(*, mihomo_client=None, notifier=None) -> FastAPI:
    """Build the app; MIHOMO_CLIENT/NOTIFIER default to the env-configured
    real ones (tests inject fakes). Construction has no side effects —
    everything stateful happens in the lifespan."""

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        client = mihomo_client if mihomo_client is not None else MihomoClient(
            config.mihomo_url(), config.controller_secret())
        notify = notifier if notifier is not None else webhook_notify
        rec = Reconciler(client=client, providers_dir=config.providers_dir(),
                         marker_path=config.marker_path(), notifier=notify)
        app.state.reconciler = rec
        app.state.mutex = threading.RLock()
        app.state.conn = None
        try:
            app.state.conn = open_db(config.db_path())
        except StoreError as exc:
            # fail-static: no file writes, no refresh - just loud state
            rec._fail(f"policy store unavailable: {exc}")
        if app.state.conn is not None:
            # startup re-sync: converge files + mihomo to the SSOT; a red
            # apply is already loud (marker/webhook/health), never fatal
            rec.apply(desired_state(app.state.conn))
        # stats (#65): a SEPARATE db - its failure degrades stats only
        # (/health collector=error), never policy serving
        app.state.stats_conn = None
        app.state.stats_lock = threading.RLock()
        app.state.collector = None
        stats_loop = None
        try:
            app.state.stats_conn = open_stats_db(config.stats_db_path())
        except StoreError:
            pass  # surfaced via /health; policy is unaffected by design
        if app.state.stats_conn is not None:
            app.state.collector = Collector(client=client,
                                            conn=app.state.stats_conn)
            interval = config.stats_poll_s()
            if interval > 0:
                stats_loop = CollectorLoop(app.state.collector,
                                           app.state.stats_lock, interval)
                stats_loop.start()
        try:
            yield
        finally:
            if stats_loop is not None:
                stats_loop.stop()
            if app.state.stats_conn is not None:
                app.state.stats_conn.close()
            if app.state.conn is not None:
                app.state.conn.close()

    app = FastAPI(title="Syno Mihomo Gateway Panel", version="1.0.0",
                  description=API_DESCRIPTION, lifespan=lifespan)
    app.include_router(router)
    # Same-origin UI (#66): the no-build static tree ships inside the
    # image and is served by the app itself - the reason the API can run
    # with ZERO CORS headers. Neither the mount nor the root redirect
    # belongs in the /v1 contract (the gate allows only /health + /v1/*).
    static_dir = Path(__file__).resolve().parent / "static"
    app.mount("/ui", StaticFiles(directory=static_dir, html=True),
              name="ui")

    @app.get("/", include_in_schema=False)
    def _root() -> RedirectResponse:
        return RedirectResponse("/ui/", status_code=307)

    return app


app = create_app()
