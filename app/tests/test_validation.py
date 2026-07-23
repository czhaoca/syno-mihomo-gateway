"""Table-driven tests for the fail-closed policy-entry validation — the
FULL_PROXY_SOURCES defect classes ported from scripts/render_config.sh
(178-255), plus the panel-specific guards (gateway/panel self-address)."""

import pytest
from app.validation import (
    ValidationError,
    canonicalize,
    cidr_contains_ip,
    cidrs_overlap,
)


@pytest.mark.parametrize(
    ("raw", "fragment"),
    [
        ("2001:db8::1", "ipv6_bypass"),
        ("2001:db8::/64", "ipv6_bypass"),
        ("host.example.com", "hostname"),
        ("192.0.2.300", "out of range"),
        ("192.0.2.0/33", "maximum /32"),
        ("192.0.2.0/", "prefix"),
        ("192.002.2.5", "leading-zero"),
        ("192.0.2.0/08", "leading-zero"),
        ("192.0.2.0/2x", "prefix"),
        ("192.0.2.0/28/24", "more than one"),
        ("192.0.2.`5`", "backtick"),
        (" 192.0.2.5", "whitespace"),
        ("192.0.2.5 ", "whitespace"),
        ("192.0\t.2.5", "whitespace"),
        ("192.0.2", "dotted-quad"),
        ("1.2.3.4.5", "dotted-quad"),
        ("192.0.2.a", "octet"),
        ("", "empty"),
    ],
)
def test_reject_classes(raw, fragment):
    with pytest.raises(ValidationError) as exc:
        canonicalize(raw)
    assert fragment in str(exc.value)


@pytest.mark.parametrize(
    ("raw", "canonical"),
    [
        ("192.0.2.5", "192.0.2.5/32"),
        ("192.0.2.16/28", "192.0.2.16/28"),
        ("0.0.0.0/0", "0.0.0.0/0"),
        ("198.51.100.7/32", "198.51.100.7/32"),
    ],
)
def test_canonicalization(raw, canonical):
    assert canonicalize(raw) == canonical


def test_zero_octet_is_legal():
    assert canonicalize("192.0.2.0/24") == "192.0.2.0/24"


@pytest.mark.parametrize(
    ("a", "b", "overlap"),
    [
        ("192.0.2.0/24", "192.0.2.5/32", True),
        ("192.0.2.16/28", "192.0.2.32/28", False),
        ("192.0.2.5/32", "192.0.2.5/32", True),
        ("0.0.0.0/0", "198.51.100.1/32", True),
        ("198.51.100.0/25", "198.51.100.128/25", False),
    ],
)
def test_overlap(a, b, overlap):
    assert cidrs_overlap(a, b) is overlap
    assert cidrs_overlap(b, a) is overlap


@pytest.mark.parametrize(
    ("cidr", "ip", "contains"),
    [
        ("192.168.1.0/24", "192.168.1.100", True),
        ("192.168.1.0/24", "203.0.113.9", False),
        ("198.51.100.7/32", "198.51.100.7", True),
    ],
)
def test_contains_ip(cidr, ip, contains):
    assert cidr_contains_ip(cidr, ip) is contains
