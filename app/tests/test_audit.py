"""Audit contract: EVERY mutation (add/flip/rename/remove/apply) appends an
entry carrying the requester IP and optional note; the trail is append-only
at the API — no delete/update surface exists for it."""

from app.tests.conftest import auth_headers


def test_every_mutation_is_audited(client, panel_env):
    h = auth_headers(panel_env)
    r = client.post("/v1/devices",
                    json={"address": "192.0.2.5", "mode": "full-tunnel",
                          "name": "tv", "note": "added by test"},
                    headers=h)
    assert r.status_code == 201
    dev = r.json()["device"]

    assert client.patch(f"/v1/devices/{dev['id']}",
                        json={"mode": "full-direct", "note": "flip note"},
                        headers=h).status_code == 200
    assert client.patch(f"/v1/devices/{dev['id']}",
                        json={"name": "tv-renamed"},
                        headers=h).status_code == 200
    assert client.post("/v1/apply", headers=h).status_code == 200
    assert client.delete(f"/v1/devices/{dev['id']}",
                         headers=h).status_code == 200

    entries = client.get("/v1/audit").json()["entries"]
    actions = [e["action"] for e in entries]
    for expected in ("add", "flip", "rename", "apply", "remove"):
        assert expected in actions, f"missing audit action {expected}: {actions}"
    add = next(e for e in entries if e["action"] == "add")
    assert add["cidr"] == "192.0.2.5/32"
    assert add["requester"], "audit entries must carry the requester IP"
    assert add["note"] == "added by test"
    flip = next(e for e in entries if e["action"] == "flip")
    assert flip["note"] == "flip note"


def test_remove_carries_optional_note(client, panel_env):
    h = auth_headers(panel_env)
    dev = client.post("/v1/devices",
                      json={"address": "192.0.2.8", "mode": "full-direct"},
                      headers=h).json()["device"]
    r = client.delete(f"/v1/devices/{dev['id']}?note=decommissioned",
                      headers=h)
    assert r.status_code == 200
    entries = client.get("/v1/audit").json()["entries"]
    removal = next(e for e in entries if e["action"] == "remove")
    assert removal["note"] == "decommissioned"


def test_api_mutation_writes_backup(client, panel_env):
    h = auth_headers(panel_env)
    assert client.post("/v1/devices",
                       json={"address": "192.0.2.6", "mode": "full-tunnel"},
                       headers=h).status_code == 201
    backups = list((panel_env["data"] / "state").glob("policy.db.bak-*"))
    assert backups, "an API mutation must produce a VACUUM INTO backup"


def test_audit_is_append_only_at_the_api(client, panel_env):
    h = auth_headers(panel_env)
    for method, path in (
        ("delete", "/v1/audit"),
        ("delete", "/v1/audit/1"),
        ("patch", "/v1/audit/1"),
        ("put", "/v1/audit/1"),
    ):
        r = getattr(client, method)(path, headers=h)
        assert r.status_code in (404, 405), \
            f"audit must be immutable: {method} {path} -> {r.status_code}"


def test_rejected_mutations_do_not_pollute_audit(client, panel_env):
    h = auth_headers(panel_env)
    assert client.post("/v1/devices",
                       json={"address": "2001:db8::1", "mode": "full-tunnel"},
                       headers=h).status_code == 422
    assert client.post("/v1/devices",
                       json={"address": "192.0.2.9", "mode": "full-tunnel"}
                       ).status_code == 403
    entries = client.get("/v1/audit").json()["entries"]
    assert entries == []


def test_gateway_and_panel_addresses_rejected(client, panel_env, monkeypatch):
    monkeypatch.setenv("MIHOMO_IP", "192.168.1.100")
    monkeypatch.setenv("PANEL_IP", "192.168.1.101")
    h = auth_headers(panel_env)
    for addr in ("192.168.1.100", "192.168.1.0/24", "192.168.1.101/32"):
        r = client.post("/v1/devices",
                        json={"address": addr, "mode": "full-tunnel"},
                        headers=h)
        assert r.status_code == 422, f"{addr} must be rejected"
        assert "gateway" in r.text or "panel" in r.text
    # an unrelated range is unaffected by the guard
    assert client.post("/v1/devices",
                       json={"address": "198.51.100.7", "mode": "full-tunnel"},
                       headers=h).status_code == 201
