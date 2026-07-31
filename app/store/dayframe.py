"""The day tier's framing: which local day a UTC hour bucket belongs to.

Pure arithmetic, no I/O, no database. It lives in its own module because
it is the one place the local-day rule exists, which makes it the one
place a wrong answer can come from - and the one place tests have to
cover. `resolve()` NEVER raises: its inputs come from `settings.get()`,
which returns whatever was stored without re-validating, and it is called
on the collector thread, where an exception is a silently dead collector.

Only the DAY tier is local-keyed (DEC-4); minute and hour stay UTC.
"""

import re
from datetime import UTC, datetime, timedelta
from typing import NamedTuple
from zoneinfo import ZoneInfo

# "HH:00" on a 24-hour clock. Anchored, so "3pm" and "25:00" are refused
# rather than silently truncated into something plausible.
#
# The minutes are pinned to 00 because the day tier is fed HOUR buckets: a
# cut at 03:30 would put the whole 03:00-03:59 hour on one side of a
# boundary that actually runs through its middle, misattributing half of
# it with a stamp claiming otherwise. A boundary the tier cannot honour at
# its own granularity is refused rather than approximated.
BOUNDARY_RE = re.compile(r"^([01]\d|2[0-3]):(00)$")

# The framing every shipped v1.8.0 row carries, and the one every degraded
# roll falls back to. Kept as literals rather than derived, because this
# pair is written into stored history and must never drift.
UTC_TZ = "UTC"
UTC_CUT = "00:00"


class DayFrame(NamedTuple):
    """A total value: either usable, or carrying the reason it is not.

    `zone is None` is the single representation of "cannot key locally".
    Callers never have to ask whether an exception happened somewhere.
    """

    tz: str          # stamped into stats_day.bucket_tz
    cut: str         # stamped into stats_day.day_boundary, "HH:MM"
    zone: object     # tzinfo, or None when unusable
    minutes: int     # cut as minutes past local midnight
    error: str       # "" when usable, else an operator-facing reason

    @property
    def ok(self) -> bool:
        return self.zone is not None


def unusable(reason: str, tz: str = "", cut: str = "") -> DayFrame:
    return DayFrame(tz, cut, None, 0, reason)


def utc_frame() -> DayFrame:
    """The UTC framing, resolved WITHOUT zoneinfo.

    Deliberate: `ZoneInfo("UTC")` itself raises when no tz database is
    installed, and this is both the framing all shipped history is stamped
    in and the fallback used when a zone will not load. A fallback that can
    fail for the same reason as the thing it is replacing is not a
    fallback.
    """
    return DayFrame(UTC_TZ, UTC_CUT, UTC, 0, "")


def resolve(tz_name, boundary) -> DayFrame:
    """The framing for a stored (timezone, day_boundary) pair. Never raises.

    `ZoneInfoNotFoundError` subclasses `KeyError`; an empty name raises
    `ValueError`; an unreadable tzfile raises `OSError`. All three are
    reachable from a value an operator can legitimately have stored - note
    `config.timezone_default()` passes `$TZ` through with no validation at
    all, and names like `PRC` or `US/Pacific` are absent from the slim
    image's tz database.
    """
    tz_name = (tz_name or "").strip()
    boundary = (boundary or "").strip()
    match = BOUNDARY_RE.match(boundary)
    if not match:
        return unusable(
            f"day_boundary {boundary!r} is not a 24-hour HH:MM time",
            tz_name, boundary)
    minutes = int(match.group(1)) * 60 + int(match.group(2))
    if tz_name == UTC_TZ:
        return DayFrame(UTC_TZ, boundary, UTC, minutes, "")
    if not tz_name:
        return unusable("no timezone is configured", tz_name, boundary)
    try:
        zone = ZoneInfo(tz_name)
    except (KeyError, ValueError, OSError) as exc:
        return unusable(
            f"timezone {tz_name!r} cannot be resolved here "
            f"({exc.__class__.__name__}) - the day tier is keying in UTC",
            tz_name, boundary)
    return DayFrame(tz_name, boundary, zone, minutes, "")


def day_key(hour_bucket: str, frame: DayFrame) -> str:
    """The local day (YYYY-MM-DD) a UTC hour bucket belongs to.

    HOUR_BUCKET is `YYYY-MM-DDTHH` in UTC, the shape the hour tier stores.

    The conversion runs UTC -> local, never the reverse: that direction is
    always defined and never ambiguous, so `fold` and nonexistent local
    times cannot arise. A local day is 23 or 25 hours twice a year and this
    still holds, because the cut is then subtracted as wall-clock
    arithmetic - "which day did the 03:00-to-03:00 window starting before
    this instant begin" - rather than as a fixed number of elapsed hours.
    """
    moment = datetime.strptime(hour_bucket[:13], "%Y-%m-%dT%H").replace(
        tzinfo=UTC)
    local = moment.astimezone(frame.zone)
    return (local - timedelta(minutes=frame.minutes)).strftime("%Y-%m-%d")
