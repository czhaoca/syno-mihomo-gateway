"""Fail-closed policy-entry validation.

Ports the FULL_PROXY_SOURCES defect classes from scripts/render_config.sh
(178-255): every poison class is rejected with a message naming the defect
BEFORE anything is stored or written; provider files are only ever emitted
from the canonical form this module returns. IPv4-only by design — the
gateway carries no IPv6, and routable LAN IPv6 bypasses it entirely (the
doctor's ipv6_bypass check owns that reality).
"""

from app import config


class ValidationError(ValueError):
    """A rejected policy entry; str(exc) names the defect class."""


def canonicalize(raw: str) -> str:
    """Validate RAW and return the canonical 'a.b.c.d/len' form
    (a bare IP normalizes to /32). Raises ValidationError otherwise."""
    if raw is None or raw == "":
        raise ValidationError("empty address")
    if "`" in raw:
        raise ValidationError("backtick is never allowed in an address")
    if any(ch.isspace() for ch in raw):
        raise ValidationError("whitespace is not allowed in an address")
    if ":" in raw:
        raise ValidationError(
            "IPv6 is not supported - the gateway is IPv4-only and routable "
            "LAN IPv6 bypasses it entirely (see the doctor's ipv6_bypass check)")
    if "/" in raw:
        ip_part, _, len_part = raw.partition("/")
        if "/" in len_part:
            raise ValidationError("more than one '/' in the address")
        if len_part == "" or not len_part.isdigit():
            raise ValidationError("prefix must be a number between /0 and /32")
        if len_part != "0" and len_part.startswith("0"):
            raise ValidationError(
                "leading-zero prefix (mihomo's parser rejects it)")
        prefix = int(len_part)
        if prefix > 32:
            raise ValidationError("prefix out of range (maximum /32)")
    else:
        ip_part, prefix = raw, 32
    octets = ip_part.split(".")
    if len(octets) != 4:
        raise ValidationError(
            "not a dotted-quad IPv4 address (hostnames are not supported)")
    for octet in octets:
        if octet == "" or not octet.isdigit():
            raise ValidationError(
                f"non-numeric octet {octet!r} (hostnames are not supported)")
        if octet != "0" and octet.startswith("0"):
            raise ValidationError(
                f"leading-zero octet {octet!r} (mihomo's parser rejects it)")
        if int(octet) > 255:
            raise ValidationError(f"octet {octet!r} out of range (0-255)")
    return f"{ip_part}/{prefix}"


def _cidr_range(cidr: str) -> tuple[int, int]:
    ip_part, _, len_part = cidr.partition("/")
    a, b, c, d = (int(o) for o in ip_part.split("."))
    base = (a << 24) | (b << 16) | (c << 8) | d
    prefix = int(len_part)
    mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF if prefix else 0
    lo = base & mask
    return lo, lo | (~mask & 0xFFFFFFFF)


def cidrs_overlap(a: str, b: str) -> bool:
    """True when the canonical CIDRs share any address."""
    a_lo, a_hi = _cidr_range(a)
    b_lo, b_hi = _cidr_range(b)
    return a_lo <= b_hi and b_lo <= a_hi


def cidr_contains_ip(cidr: str, ip: str) -> bool:
    lo, hi = _cidr_range(cidr)
    ip_lo, _ = _cidr_range(f"{ip}/32")
    return lo <= ip_lo <= hi


def check_reserved_addresses(canonical: str) -> None:
    """Reject an entry covering the gateway's or the panel's own address —
    routing the dataplane or the panel through the policy layer would sever
    the path that applies the policy. Skipped for an unset/garbage knob
    (it is a guard over configured deployments, not an input gate)."""
    for env_name, label in (("MIHOMO_IP", "gateway"), ("PANEL_IP", "panel")):
        value = config.gateway_ip() if env_name == "MIHOMO_IP" else config.panel_ip()
        if not value:
            continue
        try:
            reserved = canonicalize(value)
        except ValidationError:
            continue
        if cidrs_overlap(canonical, reserved):
            raise ValidationError(
                f"entry {canonical} covers the {label} address ({env_name}) - "
                f"refusing to policy-route the {label} itself")
