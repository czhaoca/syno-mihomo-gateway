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


@router.get("/health")
def health(request: Request) -> dict:
    rec = request.app.state.reconciler
    return {
        "db_ok": getattr(request.app.state, "conn", None) is not None,
        "parity": rec.status["parity"],
        "last_apply": rec.status["last_apply"],
        "marker": config.marker_path().exists(),
    }


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
