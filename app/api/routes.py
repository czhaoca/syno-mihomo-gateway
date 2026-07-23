"""/v1 policy API + /health.

SQLite is the SSOT: every mutation lands in the store (with its audit
entry and a VACUUM INTO backup) and is then reconciled outward; an apply
failure never rolls the store back — it surfaces honestly as
applied=false / parity=failed (plus marker + webhook), the UI's honest
apply badge. Fail-static: with the store unavailable, reads answer 503
with a structured body, mutations are refused, provider files untouched.

The /v1 surface is ADDITIVE-ONLY: a breaking change requires a new
version prefix and explicit owner acknowledgment (see the committed
app/openapi.json contract gate).
"""

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app import config
from app.api.auth import require_mutation_auth
from app.collector.core import GAP_FACTOR, effective_interval_s
from app.store import stats as stats_store
from app.store.audit import append_audit, list_audit
from app.store.policy import (
    StoreConflict,
    add_device,
    backup_db,
    desired_state,
    list_devices,
    remove_device,
    update_device,
)
from app.validation import ValidationError

router = APIRouter()

Mode = Literal["full-direct", "full-tunnel"]


class DeviceCreate(BaseModel):
    address: str = Field(description="IPv4 address or CIDR (bare IP = /32)")
    mode: Mode
    name: str = ""
    note: str = ""


class DeviceUpdate(BaseModel):
    address: str | None = None
    mode: Mode | None = None
    name: str | None = None
    note: str | None = None


def _conn(request: Request):
    conn = getattr(request.app.state, "conn", None)
    if conn is None:
        raise HTTPException(
            status_code=503,
            detail="policy store unavailable - fail-static: provider files "
                   "untouched, mutations refused (see /health and the "
                   "panel-apply-failed marker)")
    return conn


def _requester(request: Request) -> str:
    return request.client.host if request.client else ""


def _reconcile(request: Request, conn) -> dict:
    rec = request.app.state.reconciler
    applied = rec.apply(desired_state(conn))
    backup_db(conn, config.db_path(), config.backup_keep())
    return {"applied": applied, "parity": rec.status["parity"]}


def _collector_verdict(request: Request) -> tuple:
    """(verdict, last_poll_ts): error (stats.db unavailable) | off (loop
    disabled) | ok (fresh within the gap threshold) | stale."""
    stats_conn = getattr(request.app.state, "stats_conn", None)
    collector = getattr(request.app.state, "collector", None)
    last_ts = collector.status["last_poll_ts"] if collector else None
    if stats_conn is None:
        return "error", last_ts
    if config.stats_poll_s() == 0:
        return "off", last_ts
    if last_ts is None:
        return "stale", last_ts
    from datetime import UTC, datetime
    age = (datetime.now(UTC)
           - datetime.fromisoformat(last_ts.replace("Z", "+00:00")))
    fresh = age.total_seconds() <= GAP_FACTOR * effective_interval_s()
    return ("ok" if fresh else "stale"), last_ts


@router.get("/health")
def health(request: Request) -> dict:
    rec = request.app.state.reconciler
    verdict, last_poll = _collector_verdict(request)
    stats_conn = getattr(request.app.state, "stats_conn", None)
    return {
        "db_ok": getattr(request.app.state, "conn", None) is not None,
        "parity": rec.status["parity"],
        "last_apply": rec.status["last_apply"],
        "marker": config.marker_path().exists(),
        "collector": verdict,
        "collector_last_ts": last_poll,
        "stats_db_bytes": (stats_store._db_bytes(config.stats_db_path())
                           if stats_conn is not None else 0),
    }


def _stats_conn(request: Request):
    conn = getattr(request.app.state, "stats_conn", None)
    if conn is None:
        raise HTTPException(
            status_code=503,
            detail="stats store unavailable - collection degraded; policy "
                   "serving is unaffected (see /health)")
    return conn


Tier = Literal["minute", "hour", "day"]


@router.get("/v1/stats/devices")
def stats_devices(request: Request, tier: Tier = "minute",
                  since: str = "", until: str = "") -> dict:
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        return {"tier": tier,
                "rows": stats_store.read_grouped(conn, tier, "device",
                                                 since, until)}


@router.get("/v1/stats/chains")
def stats_chains(request: Request, tier: Tier = "minute",
                 since: str = "", until: str = "") -> dict:
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        return {"tier": tier,
                "rows": stats_store.read_grouped(conn, tier, "chain",
                                                 since, until)}


@router.get("/v1/stats/domains")
def stats_domains(request: Request, since: str = "",
                  until: str = "") -> dict:
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        return {"enabled": config.stats_domains(),
                "rows": stats_store.read_domains(conn, since, until)}


@router.get("/v1/stats/gaps")
def stats_gaps(request: Request, limit: int = 100) -> dict:
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        return {"rows": stats_store.read_gaps(conn, limit)}


@router.post("/v1/stats/purge",
             dependencies=[Depends(require_mutation_auth)])
def stats_purge(request: Request) -> dict:
    """Clears every visible stats surface (tiers, domains, gap history)
    but preserves conn_baseline + the poll stamp - dropping baselines
    would make still-open connections re-contribute their pre-purge
    cumulative. The POLICY audit lives in policy.db and is untouched -
    it records this purge like any other mutation."""
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        stats_store.purge_stats(conn)
    with request.app.state.mutex:
        pconn = getattr(request.app.state, "conn", None)
        if pconn is not None:
            append_audit(pconn, action="stats-purge",
                         requester=_requester(request))
    return {"purged": True}


@router.get("/v1/devices")
def get_devices(request: Request) -> dict:
    with request.app.state.mutex:
        conn = _conn(request)
        return {"devices": list_devices(conn)}


@router.post("/v1/devices", status_code=201,
             dependencies=[Depends(require_mutation_auth)])
def post_device(body: DeviceCreate, request: Request) -> dict:
    with request.app.state.mutex:
        conn = _conn(request)
        try:
            device = add_device(conn, body.address, body.mode,
                                name=body.name, note=body.note,
                                requester=_requester(request))
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        except StoreConflict as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None
        return {"device": device, **_reconcile(request, conn)}


@router.patch("/v1/devices/{device_id}",
              dependencies=[Depends(require_mutation_auth)])
def patch_device(device_id: int, body: DeviceUpdate,
                 request: Request) -> dict:
    with request.app.state.mutex:
        conn = _conn(request)
        try:
            device = update_device(conn, device_id, cidr=body.address,
                                   mode=body.mode, name=body.name,
                                   note=body.note,
                                   requester=_requester(request))
        except KeyError:
            raise HTTPException(status_code=404,
                                detail="no such device") from None
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        except StoreConflict as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None
        return {"device": device, **_reconcile(request, conn)}


@router.delete("/v1/devices/{device_id}",
               dependencies=[Depends(require_mutation_auth)])
def delete_device(device_id: int, request: Request, note: str = "") -> dict:
    """NOTE rides a query parameter (DELETE bodies are non-portable) and
    lands on the removal's audit entry — every mutation carries requester
    IP + optional note."""
    with request.app.state.mutex:
        conn = _conn(request)
        try:
            removed = remove_device(conn, device_id,
                                    requester=_requester(request), note=note)
        except KeyError:
            raise HTTPException(status_code=404,
                                detail="no such device") from None
        return {"removed": removed["id"], **_reconcile(request, conn)}


@router.post("/v1/apply", dependencies=[Depends(require_mutation_auth)])
def post_apply(request: Request) -> dict:
    with request.app.state.mutex:
        conn = _conn(request)
        append_audit(conn, action="apply", requester=_requester(request))
        return _reconcile(request, conn)


@router.get("/v1/audit")
def get_audit(request: Request, limit: int = 200, offset: int = 0) -> dict:
    with request.app.state.mutex:
        conn = _conn(request)
        return {"entries": list_audit(conn, limit=limit, offset=offset)}
