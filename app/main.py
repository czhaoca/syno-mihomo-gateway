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
from fastapi.responses import PlainTextResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from app import config
from app.api.routes import router
from app.collector.core import Collector, CollectorLoop
from app.mihomo_client.client import MihomoClient
from app.notify import webhook_notify
from app.reconciler.core import Reconciler
from app.store import dayframe, settings
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
            def day_source():
                """The day tier's framing, resolved FRESH every maintenance
                pass so a settings change lands within 60s without a panel
                restart. The POLICY connection is read here rather than
                handed to the collector: the connection alone is not the
                unit of safety, it needs `app.state.mutex` with it."""
                pconn = app.state.conn
                if pconn is None:
                    return dayframe.unusable(
                        "the policy store is unavailable, so the configured "
                        "timezone cannot be read")
                with app.state.mutex:
                    tz = settings.get(pconn, "timezone")
                    cut = settings.get(pconn, "day_boundary")
                return dayframe.resolve(tz, cut)

            app.state.collector = Collector(client=client,
                                            conn=app.state.stats_conn,
                                            day_source=day_source)
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
    # Same-origin UI (#66, rebuilt in React at #80): the built tree ships
    # inside the image and is served by the app itself - the reason the API
    # can run with ZERO CORS headers. Neither the mount nor the root redirect
    # belongs in the /v1 contract (the gate allows only /health + /v1/*).
    #
    # `dist/` is gitignored and built by app/Dockerfile, so a bare source
    # checkout has none. That must fail LOUDLY rather than 404: a mysterious
    # missing page reads like a routing bug, and the fix is one command. The
    # placeholder deliberately carries no `data-i18n="app_title"`, so release
    # phase A6 - which greps that marker out of raw HTML - can never mistake
    # an unbuilt panel for a working one.
    ui_dist = Path(__file__).resolve().parent / "ui" / "dist"
    if (ui_dist / "index.html").exists():
        app.mount("/ui", StaticFiles(directory=ui_dist, html=True), name="ui")
    else:
        @app.get("/ui/{path:path}", include_in_schema=False)
        def _ui_unbuilt(path: str = "") -> PlainTextResponse:
            return PlainTextResponse(
                "The panel UI is not built in this checkout.\n"
                "Run: npm --prefix app/ui ci && npm --prefix app/ui run build\n"
                "(the shipped image builds it during docker build).\n",
                status_code=503)

    @app.get("/", include_in_schema=False)
    def _root() -> RedirectResponse:
        return RedirectResponse("/ui/", status_code=307)

    return app


app = create_app()
