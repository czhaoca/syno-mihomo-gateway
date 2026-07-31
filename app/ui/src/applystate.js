/* The apply-state machine, carried over from the classic tree UNCHANGED.

   This is the panel's honesty contract, not incidental UI state: a badge
   must never claim a change reached mihomo when it did not. `confirmed` is
   only ever written from the API's OWN answer - `applied === true` AND
   `parity === "ok"` - never assumed because a write returned 200. Anything
   else is drift, including a 200 whose body says the apply failed.

   Session-scoped and per-cidr, deliberately module-level rather than React
   state: it must survive a view switch (the classic Map did), and it is read
   during render so a re-render after any refresh picks it up. */

const applyState = new Map();

export function badgeFor(cidr, parity) {
  return applyState.get(cidr) || (parity === "failed" ? "drift" : "saved");
}

export function noteApplyResult(cidr, body) {
  if (body && body.applied === true && body.parity === "ok") {
    applyState.set(cidr, "confirmed");
  } else {
    applyState.set(cidr, "drift");
  }
}

export function markApplying(cidr) {
  applyState.set(cidr, "applying");
}

export function markDrift(cidr) {
  applyState.set(cidr, "drift");
}

export function forget(cidr) {
  applyState.delete(cidr);
}

// A successful re-apply is the one event that clears every remembered
// verdict: the whole desired state was just pushed and confirmed.
export function clearAll() {
  applyState.clear();
}
