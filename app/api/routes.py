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

import sqlite3
from contextlib import contextmanager, suppress
from datetime import UTC, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Body, Depends, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator

from app import config
from app.api.auth import require_mutation_auth
from app.collector.core import GAP_FACTOR, effective_interval_s
from app.store import dayframe, identity, settings
from app.store import stats as stats_store
from app.store.audit import append_audit, list_audit
from app.store.db import StoreError, open_reader
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


class SettingsUpdate(BaseModel):
    values: dict[str, str] = Field(
        default_factory=dict,
        description="Overrides to apply; a blank value reverts that key to "
                    "its code default")
    note: str = Field(
        default="",
        description="Recorded on the audit entry for this change")


# The tables a scoped purge may name - stats_store.PURGE_TABLES, spelled out
# so the contract lists them (a test pins the two together).
PurgeTable = Literal[
    "stats_minute", "stats_minute_v5", "stats_hour", "stats_day",
    "stats_domain", "stats_coverage", "stats_gap",
    "stats_exit_hour", "stats_exit_day", "stats_rule_hour", "stats_rule_day",
    "stats_category_hour", "stats_category_day", "stats_country_hour",
    "stats_country_day", "stats_sniff", "stats_asn", "stats_port",
    "stats_self"]


class StatsPurge(BaseModel):
    # a destructive call: a misspelt key must be refused, not ignored into
    # "purge everything"
    model_config = ConfigDict(extra="forbid")

    device: str | None = Field(
        default=None, min_length=1,
        description="Only this device's rows. The gap history has no device "
                    "and is kept")
    tables: list[PurgeTable] | None = Field(
        default=None, min_length=1,
        description="Only these tables")
    before: str | None = Field(
        default=None, pattern=r"^\d{4}-\d{2}-\d{2}(T\d{2}(:\d{2})?)?$",
        description="Only rows whose bucket STARTS before this UTC moment "
                    "(`YYYY-MM-DD`, `YYYY-MM-DDTHH` or `YYYY-MM-DDTHH:MM`): "
                    "a bucket straddling it goes too, so nothing older "
                    "survives. A day row is compared by its date")

    @field_validator("before")
    @classmethod
    def _real_moment(cls, value):
        # the pattern admits 2026-13-45; the calendar does not
        if value is not None:
            datetime.strptime(value, {10: "%Y-%m-%d", 13: "%Y-%m-%dT%H",
                                      16: "%Y-%m-%dT%H:%M"}[len(value)])
        return value


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
        **_telemetry(request, last_poll),
        # The day tier's framing (#76). FLAT keys deliberately: the doctor
        # reads /health with a sed scalar extractor (checks.sh _ph_field),
        # which cannot see into a nested object. `day_framing` is
        # ok|degraded|unknown - degraded means the configured zone would
        # not resolve and the tier is keying in UTC, which the rows say
        # too. It is reported here rather than through `last_error`,
        # because every successful poll clears that within 10s while
        # maintenance only runs once a minute: the symptom would erase
        # itself faster than it could appear.
        **_day_status(request),
    }


def _telemetry(request: Request, last_poll) -> dict:
    """The collector's self-telemetry (#96) - FLAT keys, counts and numbers
    only, never error text; None is "not measured yet", never 0.

    `collector_interval_s` and `stats_cap_mb` are the values the app is
    actually running with (DEC-C): the doctor and the release validator
    judge "a poll slower than half its interval" and "90 % of the cap"
    against these instead of re-parsing the knobs, which could drift from
    the app's own defaults or describe an .env not yet redeployed."""
    collector = getattr(request.app.state, "collector", None)
    status = getattr(collector, "status", None) or {}
    from app.collector.core import _lag_s, _now_str
    return {
        "collector_lag_s": _lag_s(last_poll, _now_str()),
        "collector_poll_ms": status.get("poll_ms"),
        "collector_conns": status.get("conns"),
        "collector_failed_polls": status.get("failed_polls", 0),
        "collector_interval_s": config.stats_poll_s(),
        "stats_cap_mb": config.stats_cap_mb(),
        "stats_db_growth_mb_day": status.get("db_growth_mb_day"),
        "mihomo_mem_mb": status.get("mihomo_mem_mb"),
        "mihomo_version": status.get("mihomo_version", ""),
    }


def _day_status(request: Request) -> dict:
    collector = getattr(request.app.state, "collector", None)
    status = getattr(collector, "status", None) or {}
    return {
        "day_tz": status.get("day_tz", ""),
        "day_cut": status.get("day_cut", ""),
        "day_framing": status.get("day_framing", "unknown"),
    }


def _stats_conn(request: Request):
    conn = getattr(request.app.state, "stats_conn", None)
    if conn is None:
        raise HTTPException(
            status_code=503,
            detail="stats store unavailable - collection degraded; policy "
                   "serving is unaffected (see /health)")
    return conn


@contextmanager
def _stats_reader(request: Request):
    """A per-request READ-ONLY connection for a stats read (#93).

    Reads used to take the one stats connection under the lock the collector
    holds for its flush and its maintenance pass, so a slow rollup or cap
    prune stalled every stats view. A reader opened here sees the last
    committed snapshot through WAL and never touches that lock, which is
    left to the writer (collector + purge) alone.

    The whole response is read inside ONE read transaction, so a body built
    from several queries (window rows + framings, the coverage report)
    still describes a single moment - the guarantee the lock used to give.
    The writer connection must be up: it is what ran the migrations, and a
    degraded store answers the same 503 as before.
    """
    _stats_conn(request)
    try:
        conn = open_reader(config.stats_db_path())
    except StoreError as exc:
        raise HTTPException(
            status_code=503,
            detail="stats store unavailable - collection degraded; policy "
                   "serving is unaffected (see /health)") from exc
    try:
        conn.execute("BEGIN")
        yield conn
    finally:
        with suppress(sqlite3.Error):
            conn.execute("ROLLBACK")  # read-only: ending the snapshot is all
        conn.close()


Tier = Literal["minute", "hour", "day"]

# The range vocabulary (#91) - settings.STATS_RANGES is the one list; a test
# pins this Literal and stats_store.RANGE_SPECS to it.
StatsRange = Literal["48h", "7d", "30d", "daily"]

RangeParam = Annotated[StatsRange | None, Query(
    alias="range",
    description=(
        "A window preset: `48h` (minute resolution), `7d` and `30d` (hour "
        "resolution), `daily` (local-day resolution, everything held). The "
        "server computes the window from its own clock and reads it "
        "WINDOW-COMPLETE. The hour tier is written at every poll, so a minute "
        "or hour read takes its own tier alone, and a day read takes the day "
        "tier plus the hour tier, which holds the days not rolled up yet - so "
        "a 7-day total includes the newest 48 hours and `daily` includes "
        "today. A window ends at the resolution tier's retention: with the "
        "shipped retention every preset is whole, and an explicit `tier` "
        "finer than the window (e.g. `range=7d&tier=minute`) reaches back "
        "only as far as that tier holds. An explicit `tier` overrides the "
        "resolution only. Mutually exclusive with `since`/`until`, even empty "
        "ones (422). Without `range`, a read covers the single `tier` table "
        "(since v1.11 the hour table also holds the newest 48 hours)."))]


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _range_args(request: Request, range_: str, tier: str):
    """(resolution, window start, frame) for a `range=` read.

    The day framing is resolved only for a DAY-resolution read - the only
    one that keys anything by local day - and HERE, before the caller opens
    its reader. The production source reads the timezone from policy.db
    under the POLICY mutex, which a policy change holds across its mihomo
    controller calls: resolving it for every read would put the landing 7d
    view behind each policy apply in flight.
    """
    # presence, not value: `since=` sent empty is still a second way of
    # naming the window, and accepting it would make the refusal depend on
    # what a client happened to fill in
    if "since" in request.query_params or "until" in request.query_params:
        raise HTTPException(
            status_code=422,
            detail="range and since/until are mutually exclusive - range sets "
                   "the window; send one or the other")
    resolution, start = stats_store.range_window(range_, _utcnow())
    if "tier" in request.query_params:
        resolution = tier
    frame = dayframe.utc_frame()  # unused below day resolution
    if resolution == "day":
        collector = getattr(request.app.state, "collector", None)
        if collector is not None:
            frame = collector.day_frame()
    return resolution, start, frame


def _range_grouped(request: Request, group_col: str, range_: str,
                   tier: str) -> dict:
    resolution, start, frame = _range_args(request, range_, tier)
    with _stats_reader(request) as conn:
        body = {"tier": resolution,
                "rows": stats_store.read_window_grouped(conn, resolution,
                                                        group_col, start,
                                                        frame)}
        if resolution == "day":
            body["framings"] = stats_store.window_framings(conn, start, frame)
        return body


def _day_framings(conn, tier: str, since: str, until: str) -> dict:
    """Day-tier totals sum ACROSS framings, which is arithmetically exact -
    every hour bucket rolls exactly once. What the sum cannot show is that
    the day BOUNDARY moved inside the requested window, so the framings
    present travel with the totals. More than one means the window is a
    union of differently-defined days, not a single 24-hour one.

    Absent on the minute and hour tiers, which have no framing at all.
    """
    if tier != "day":
        return {}
    return {"framings": stats_store.day_framings(conn, since, until)}


@router.get("/v1/stats/devices")
def stats_devices(request: Request, tier: Tier = "minute",
                  since: str = "", until: str = "",
                  range_: RangeParam = None) -> dict:
    """Per-device totals. With `range`, window-complete across tiers; with
    only `tier`, the single tier table (unchanged since v1.8.0)."""
    if range_ is not None:
        return _range_grouped(request, "device", range_, tier)
    with _stats_reader(request) as conn:
        return {"tier": tier,
                "rows": stats_store.read_grouped(conn, tier, "device",
                                                 since, until),
                **_day_framings(conn, tier, since, until)}


@router.get("/v1/stats/chains")
def stats_chains(request: Request, tier: Tier = "minute",
                 since: str = "", until: str = "",
                 range_: RangeParam = None) -> dict:
    """Per-chain totals. With `range`, window-complete across tiers; with
    only `tier`, the single tier table (unchanged since v1.8.0)."""
    if range_ is not None:
        return _range_grouped(request, "chain", range_, tier)
    with _stats_reader(request) as conn:
        return {"tier": tier,
                "rows": stats_store.read_grouped(conn, tier, "chain",
                                                 since, until),
                **_day_framings(conn, tier, since, until)}


@router.get("/v1/stats/domains")
def stats_domains(request: Request, since: str = "",
                  until: str = "") -> dict:
    with _stats_reader(request) as conn:
        return {"enabled": config.stats_domains(),
                "rows": stats_store.read_domains(conn, since, until)}


@router.get("/v1/stats/timeline")
def stats_timeline(request: Request, tier: Tier = "minute",
                   device: str = "", since: str = "",
                   until: str = "", range_: RangeParam = None) -> dict:
    """Bucket rows, optionally for one device. With `range`, window-complete
    across tiers at the resolution (local days synthesised under the current
    framing for the not-yet-rolled tail, stamped like stored ones); with
    only `tier`, the single tier table (unchanged since v1.8.0)."""
    if range_ is not None:
        resolution, start, frame = _range_args(request, range_, tier)
        with _stats_reader(request) as conn:
            return {"tier": resolution, "device": device,
                    "rows": stats_store.read_window_timeline(
                        conn, resolution, device, start, frame)}
    with _stats_reader(request) as conn:
        return {"tier": tier, "device": device,
                "rows": stats_store.read_timeline(conn, tier, device,
                                                  since, until)}


@router.get("/v1/stats/coverage")
def stats_coverage(request: Request, since: str = "", until: str = "") -> dict:
    """What share of traffic could be attributed to an app at all (#77).

    DEC-6 makes this the deliverable: the per-app feature exists to enable
    BLOCKING, and blocking on bad attribution takes out the wrong app on a
    gateway carrying all LAN traffic. So the number comes first, and it is
    measured rather than assumed.

    A flow counts as attributable only when it carried a hostname (DEC-B).
    Routing signals never promote one - `rule`/`rulePayload` name a
    routing category, not an application, and the release gate already
    refuses to read `GeoSite/cn` as proof of anything. `rules` breaks the
    unattributable remainder down by the rule that routed it, which is
    what distinguishes a deliberate exclusion from a real gap.

    No hostname is stored to produce this: the counters are hostname-free
    by construction, so the report needs none of the privacy surface the
    opt-in domain table carries.
    """
    with _stats_reader(request) as conn:
        return stats_store.coverage_report(conn, since, until)


@router.get("/v1/stats/self")
def stats_self(request: Request, since: str = "", until: str = "") -> dict:
    """The collector's own gauges (#96), one row per maintenance pass
    (about a minute), kept 7 days: poll duration (ms, the mean of the last
    30 polls), connections in the last snapshot, failed polls since the
    panel started, seconds since the last good poll, stats.db bytes, and
    mihomo's in-use memory (MiB). `null` is "not measured", never 0.
    `since`/`until` compare against the minute keys (`YYYY-MM-DDTHH:MM`, UTC)
    as strings, like every stats read: `until=2026-10-16` ends BEFORE that
    day; `until=2026-10-16T23:59` includes it."""
    with _stats_reader(request) as conn:
        return {"retention_days": stats_store.DOMAIN_RETENTION_DAYS,
                "rows": stats_store.read_self(conn, since, until)}


@router.get("/v1/stats/gaps")
def stats_gaps(request: Request, limit: int = 100) -> dict:
    with _stats_reader(request) as conn:
        return {"rows": stats_store.read_gaps(conn, limit)}


@router.post("/v1/stats/purge",
             dependencies=[Depends(require_mutation_auth)])
def stats_purge(request: Request,
                scope: Annotated[StatsPurge | None, Body()] = None) -> dict:
    """Clears every visible stats surface (tiers, dimensions, the seven-day
    tables, gap history) but preserves conn_baseline + the poll stamp -
    dropping baselines would make still-open connections re-contribute
    their pre-purge cumulative. An optional body narrows it to one
    `device`, some `tables`, rows `before` a moment, or any combination;
    no body (or `{}`) clears everything, as it always has. `rows` counts
    what each table lost. The POLICY audit lives in policy.db and is
    untouched - it records this purge, with its scope, like any other
    mutation."""
    scope = scope or StatsPurge()
    with request.app.state.stats_lock:
        conn = _stats_conn(request)
        rows = stats_store.purge_stats(
            conn, device=scope.device or "", tables=scope.tables,
            before=scope.before or "")
    details = " ".join(
        f"{key}={','.join(val) if isinstance(val, list) else val}"
        for key, val in sorted(scope.model_dump(exclude_none=True).items()))
    with request.app.state.mutex:
        pconn = getattr(request.app.state, "conn", None)
        if pconn is not None:
            append_audit(pconn, action="stats-purge",
                         requester=_requester(request), details=details)
    return {"purged": True, "rows": rows}


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

    Since #82 a name has exactly one home. A HOST's name is this `alias`
    (identity-scoped, survives the policy being removed); migration v5
    emptied every /32's `devices.name` and the panel never writes one
    again. A RANGE cannot carry an alias (identity keys on a /32), so its
    `name` stays in the policy row - the only home it can have.

    Both fields still ride the payload unchanged: /v1 is additive-only, so
    `name` stays PATCHable everywhere and a raw-API writer can put text
    into a host's policy row - that field is dead storage the interface
    ignores in favour of the alias (`displayName`, the one place the
    precedence rule lives, #80 DEC-C narrowed by #82).
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


@router.get("/v1/settings")
def get_settings(request: Request) -> dict:
    """Every known setting with its effective value, the default it would
    fall back to, and whether an override is in force.

    Reporting all three is deliberate: an inherited value shown as if it
    were a stored choice is the same class of lie as a badge that claims
    an apply reached mihomo when it did not. The timezone default is the
    container's own `TZ`, so an untouched panel agrees with mihomo and the
    updater about what "today" means.
    """
    with request.app.state.mutex:
        return {"settings": settings.effective(_conn(request))}


@router.put("/v1/settings", dependencies=[Depends(require_mutation_auth)])
def put_settings(body: SettingsUpdate, request: Request) -> dict:
    """Apply a partial map of overrides. A blank value REVERTS that key to
    its code default rather than storing an empty string.

    The batch is all-or-nothing: every key and value is validated before
    anything is written, so a typo cannot leave half a change behind. This
    diverges from `POST /v1/identities/import`, whose per-row ledger is
    the honest answer there because the rows are independent hosts - a
    settings write is a single operator intent.

    `changed` lists the keys whose stored OVERRIDE moved. That is broader
    than "the resolved value moved" on purpose: pinning today's default, or
    reverting a pin that equals today's default, changes nothing visible now
    but changes what a later redeploy does. Re-sending an identical
    configuration is still a truthful no-op.
    """
    with request.app.state.mutex:
        conn = _conn(request)
        try:
            changed = settings.apply_values(
                conn, body.values, requester=_requester(request),
                note=body.note)
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from None
        return {"settings": settings.effective(conn), "changed": changed}


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
