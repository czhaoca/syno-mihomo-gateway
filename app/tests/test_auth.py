"""Auth matrix (DEC-6): empty PANEL_SECRET => reads open, ALL mutations 403
even with a token; set secret => bearer-gated mutations, constant 403 on
wrong/missing tokens; the token is never echoed; zero CORS headers ever."""

from app.main import create_app
from app.tests.conftest import auth_headers
from fastapi.testclient import TestClient

MUTATION_CALLS = [
    ("post", "/v1/devices", {"address": "192.0.2.5", "mode": "full-tunnel"}),
    ("patch", "/v1/devices/1", {"mode": "full-direct"}),
    ("delete", "/v1/devices/1", None),
    ("post", "/v1/apply", None),
]


def _call(c, method, path, body, headers=None):
    kwargs = {"headers": headers or {}}
    if body is not None:
        kwargs["json"] = body
    return getattr(c, method)(path, **kwargs)


def test_empty_secret_reads_open_mutations_403(panel_env, fake_client, notifier,
                                               monkeypatch):
    monkeypatch.setenv("PANEL_SECRET", "")
    app = create_app(mihomo_client=fake_client, notifier=notifier)
    with TestClient(app) as c:
        assert c.get("/v1/devices").status_code == 200
        assert c.get("/v1/audit").status_code == 200
        assert c.get("/health").status_code == 200
        for method, path, body in MUTATION_CALLS:
            r = _call(c, method, path, body)
            assert r.status_code == 403, f"{method} {path}: {r.status_code}"
            assert "PANEL_SECRET" in r.json()["detail"]
            # even presenting a token cannot unlock an empty-secret panel
            r = _call(c, method, path, body,
                      headers={"Authorization": "Bearer anything"})
            assert r.status_code == 403


def test_set_secret_gates_mutations(client, panel_env):
    for method, path, body in MUTATION_CALLS:
        r = _call(client, method, path, body)
        assert r.status_code == 403, f"no token {method} {path}"
        r = _call(client, method, path, body,
                  headers={"Authorization": "Bearer wrong-token"})
        assert r.status_code == 403, f"wrong token {method} {path}"
        r = _call(client, method, path, body,
                  headers={"Authorization": "Basic dXNlcjpwdw=="})
        assert r.status_code == 403, f"non-bearer {method} {path}"
    r = client.post("/v1/devices",
                    json={"address": "192.0.2.5", "mode": "full-tunnel"},
                    headers=auth_headers(panel_env))
    assert r.status_code == 201
    # reads stay open with the secret set
    assert client.get("/v1/devices").status_code == 200


def test_token_never_echoed(client, panel_env):
    secret = panel_env["secret"]
    r = client.post("/v1/devices", json={"address": "192.0.2.5",
                                         "mode": "full-tunnel"})
    assert secret not in r.text
    r = client.post("/v1/devices", json={"address": "192.0.2.5",
                                         "mode": "full-tunnel"},
                    headers={"Authorization": "Bearer sniff-me-token"})
    assert "sniff-me-token" not in r.text
    r = client.post("/v1/devices",
                    json={"address": "192.0.2.5", "mode": "full-tunnel"},
                    headers=auth_headers(panel_env))
    assert secret not in r.text


def test_no_cors_headers_anywhere(client, panel_env):
    origin = {"Origin": "http://198.51.100.1"}
    responses = [
        client.get("/health", headers=origin),
        client.get("/v1/devices", headers=origin),
        client.post("/v1/devices", json={"address": "192.0.2.5",
                                         "mode": "full-tunnel"},
                    headers={**auth_headers(panel_env), **origin}),
        client.options("/v1/devices", headers={
            **origin, "Access-Control-Request-Method": "POST"}),
    ]
    for r in responses:
        for header in r.headers:
            assert not header.lower().startswith("access-control-"), \
                f"CORS header leaked: {header}"


def test_secret_absent_from_health_and_errors(client, panel_env):
    assert panel_env["secret"] not in client.get("/health").text
    r = client.post("/v1/devices", json={"address": "not-an-ip",
                                         "mode": "full-tunnel"},
                    headers=auth_headers(panel_env))
    assert r.status_code == 422
    assert panel_env["secret"] not in r.text
