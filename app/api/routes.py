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
from app.store import identity
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


class IdentityUpdate(BaseModel):
    alias: str = Field(
        default="",
        description="Human name for this host; blank removes the alias")


class IdentityImportEntry(BaseModel):
    ip: str = Field(description="IPv4 host address (a range is refused)")
    alias: str = Field(description="Human name; blank is refused on import")
    source: str = Field(
        description="Where this alias came from, e.g. unifi or nimbus. "
                    "'hand-edit' is reserved for an operator's own edit")


class IdentityImport(BaseModel):
    entries: list[IdentityImportEntry] = Field(default_factory=list)
    override: bool = Field(
        default=False,
        description="Adopt hosts whose alias was typed by an operator. "
                    "Attended use only - a scheduled sync leaves this off")


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
        # the UI builds the MetaCubexD deep-link from location.hostname +
        # this port (DEC-12: node ops stay on the dashboard; no URL
        # literal may live in the static tree)
        "dashboard_port": config.dashboard_port(),
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


@router.get("/v1/stats/timeline")
def stats_timeline(request: Request, tier: Tier = "minute",
                   device: str = "", since: str = "",
                   until: str = "") -> dict:
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        return {"tier": tier, "device": device,
                "rows": stats_store.read_timeline(conn, tier, device,
                                                  since, until)}


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


def _band_entries() -> list:
    """FULL_PROXY_SOURCES parsed to canonical CIDRs; invalid entries (or
    an unset knob - the norm until compose wires it at Sequence 60)
    degrade to an empty band, never an error - the badge is advisory."""
    from app.validation import ValidationError, canonicalize
    entries = []
    for raw in config.full_proxy_sources().split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            entries.append(canonicalize(raw))
        except ValidationError:
            continue
    return entries


def _with_band_flags(rows: list) -> list:
    from app.validation import cidrs_overlap
    band = _band_entries()
    for row in rows:
        row["band_member"] = any(
            cidrs_overlap(row["cidr"], entry) for entry in band)
    return rows


def _with_aliases(conn, rows: list) -> list:
    """Decorate on the way out, so the policy store stays free of identity.
    Exact /32 match only - a range has no single host, and lending it the
    alias of an address it contains would put one device's name on a whole
    subnet.

    A policied device can therefore carry TWO human names: the shipped
    `devices.name` (policy-scoped, PATCHable, audited as `rename`) and this
    `alias` (identity-scoped, survives the policy being removed). They are
    both returned and neither is derived from the other. The shipped UI
    still renders `name`; deciding which one wins in the interface belongs
    to the React device views (#80), which is where a precedence rule can
    be applied consistently rather than guessed at per call site.
    """
    aliases = identity.resolve(conn)
    for row in rows:
        row["alias"] = aliases.get(row["cidr"], "")
    return rows


@router.get("/v1/devices")
def get_devices(request: Request) -> dict:
    """`band` (the canonical FULL_PROXY_SOURCES entries) rides along so
    the UI can gate a NEW override on a band address with a confirm
    BEFORE posting — DEC-4 covers adds, not just flips on listed rows."""
    with request.app.state.mutex:
        conn = _conn(request)
        rows = _with_aliases(conn, _with_band_flags(list_devices(conn)))
        return {"devices": rows, "band": _band_entries()}


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


@router.get("/v1/identity")
def get_identity(request: Request) -> dict:
    """Aliases for hosts that may or may not carry a routing policy - the
    reason this is not folded into /v1/devices, which only ever lists
    devices that HAVE one."""
    with request.app.state.mutex:
        return {"identities": identity.list_aliases(_conn(request))}


@router.put("/v1/identity/{ip}",
            dependencies=[Depends(require_mutation_auth)])
def put_identity(ip: str, body: IdentityUpdate, request: Request) -> dict:
    """Set (or clear) the alias for one host. PUT replaces the resource, so
    a body carrying no alias clears it - `removed` reports whether a row
    actually went away, since the cleared state is otherwise identical to
    an address that never had one.

    Naming a device applies no policy and triggers no reconcile: there is
    nothing for the gateway to do about a label. That also means an alias
    write is NOT followed by a `backup_db` the way a policy mutation is -
    aliases enter a backup on the next policy change (deliberate: a bulk
    import must not VACUUM per row).

    `{ip}` is a single host by construction. A CIDR's `/` is a path
    separator, so a range cannot address this endpoint at all.
    """
    with request.app.state.mutex:
        conn = _conn(request)
        try:
            result = identity.set_alias(conn, ip, body.alias,
                                        requester=_requester(request))
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        return {"identity": {"ip": result["ip"], "alias": result["alias"]},
                "source": result.get("source", identity.HAND),
                "removed": result.get("removed", False)}


@router.delete("/v1/identity/{ip}",
               dependencies=[Depends(require_mutation_auth)])
def delete_identity(ip: str, request: Request) -> dict:
    """Answers 200 with `removed: false` when there was no alias, NOT 404.
    This diverges deliberately from `DELETE /v1/devices/{id}`: a device id
    either names a resource or does not, whereas every valid host address
    exists whether or not it carries a label, so "there was nothing to
    remove" is a truthful outcome rather than a missing resource.
    """
    with request.app.state.mutex:
        conn = _conn(request)
        try:
            removed = identity.remove_alias(conn, ip,
                                            requester=_requester(request))
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        return {"removed": removed}


@router.post("/v1/identities/import",
             dependencies=[Depends(require_mutation_auth)])
def post_identities_import(body: IdentityImport, request: Request) -> dict:
    """Bulk-import aliases from ANY source. Vendor-agnostic on purpose:
    `source` is just a label, so UniFi, Nimbus and a hand-written file all
    use this one path and no vendor code or credential lives in the panel.

    An alias an operator typed OUTRANKS every importer, so a row whose
    recorded source differs is left alone. The response is therefore a
    per-row LEDGER rather than a count - a skip is a designed refusal, and
    the caller has to see WHICH hosts kept their typed name. Reporting only
    a total would hide exactly the case the rule exists to protect.

    `override: true` is the attended escape hatch, so re-pointing a renamed
    host at its vendor name does not require destroying the name first.
    """
    with request.app.state.mutex:
        conn = _conn(request)
        report = identity.import_aliases(
            conn, [e.model_dump() for e in body.entries],
            requester=_requester(request), override=body.override)
        # one backup for the batch, never per row: a VACUUM INTO per alias
        # would make a large sync pathological
        if report["changed"]:
            backup_db(conn, config.db_path(), config.backup_keep())
        return report


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
