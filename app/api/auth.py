"""PANEL_SECRET bearer auth (DEC-6).

Reads are LAN-open; EVERY mutation requires `Authorization: Bearer
<PANEL_SECRET>`. An empty knob fails CLOSED: all mutations 403 — there is
no valid token when no secret is set. Constant-time compare; the presented
token is never echoed, logged, or embedded in error bodies. All failures
are 403 (never 401 — no WWW-Authenticate negotiation surface).
"""

import hmac

from fastapi import HTTPException, Request

from app import config


def require_mutation_auth(request: Request) -> None:
    secret = config.panel_secret()
    if not secret:
        raise HTTPException(
            status_code=403,
            detail="mutations disabled: PANEL_SECRET is not set")
    header = request.headers.get("Authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(
            token.encode(), secret.encode()):
        raise HTTPException(
            status_code=403, detail="invalid or missing bearer token")
