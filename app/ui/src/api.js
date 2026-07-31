/* The panel's HTTP client. Carried over from the classic tree's `api()`
   (app/static/app.js) with its failure semantics intact, because those are
   load-bearing rather than incidental:

   - `fetch` REJECTS when the panel is unreachable rather than resolving
     with a status, so without the catch the failure escapes every caller
     and every view keeps rendering stale data with nothing saying so.
     Status 0 means "never reached the panel" and is falsy for every
     `status === 200` check.
   - A 403 on a MUTATING call prompts for the token once and retries. The
     prompt is a singleton: a second 403 arriving while the dialog is open
     must share the same pending answer, not open a second dialog. */

export function token() {
  return localStorage.getItem("panel_token") || "";
}

export function setToken(value) {
  localStorage.setItem("panel_token", value);
}

// The React shell owns the dialog; this module owns the retry rule. Keeping
// them apart is what lets any view call api() without threading a dialog
// handle through its props.
let askTokenImpl = null;
let tokenPromise = null;

export function registerTokenPrompt(fn) {
  askTokenImpl = fn;
}

function askToken() {
  if (tokenPromise) return tokenPromise;
  const pending = askTokenImpl ? askTokenImpl() : Promise.resolve(false);
  tokenPromise = pending.then(
    (ok) => { tokenPromise = null; return ok; },
    (err) => { tokenPromise = null; throw err; },
  );
  return tokenPromise;
}

export async function api(method, path, body) {
  const headers = {};
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const mutating = method !== "GET";
  if (mutating && token()) headers["Authorization"] = `Bearer ${token()}`;
  let res;
  try {
    res = await fetch(path, {
      method, headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  } catch {
    return { status: 0, data: null };
  }
  if (res.status === 403 && mutating) {
    const entered = await askToken();
    if (entered) return api(method, path, body);
  }
  let data = null;
  try { data = await res.json(); } catch { data = null; }
  return { status: res.status, data };
}
