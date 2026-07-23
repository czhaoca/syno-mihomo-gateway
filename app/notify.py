"""Webhook notifier — the scripts/lib/notify.sh JSON contract
({"title": ..., "body": ...} POST). The URL often embeds a token, so it is
read from the environment at send time and NEVER logged, echoed, or
included in any error. Delivery is best-effort: a panel failure path must
never die on a dead webhook.
"""

import http.client
import json
import urllib.request

from app import config

TIMEOUT_S = 10


def webhook_notify(title: str, body: str) -> bool:
    url = config.webhook_url()
    if not url:
        return False
    payload = json.dumps({"title": title, "body": body}).encode()
    try:
        # Request construction itself raises ValueError on a malformed URL
        # — it must sit INSIDE the guard: a garbage knob degrades, never
        # crashes a failure path.
        req = urllib.request.Request(
            url, data=payload, method="POST",
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_S):
            return True
    except (OSError, ValueError, http.client.HTTPException):
        # HTTPException covers InvalidURL (control chars / spaces in the
        # host survive Request() and explode in urlopen) — degrade, never
        # crash, and never log the URL (it can embed a token).
        return False
