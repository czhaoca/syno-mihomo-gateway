import { useCallback, useEffect, useState } from "react";

import { NO_DICTIONARY, RANGES } from "../stats.js";

/* The panel's routes (#101 DEC-A), kept in the URL hash so the back button,
   a reload and a link from another tab all land on the same scope. The hash
   never reaches the server, so FastAPI and the A6 release grep see nothing
   new.

     #/insights[?range=R]                       the overview
     #/insights/client/<ip>                     one device
     #/insights/app/<category>                  one category value
     #/insights/host/<hostname>                 one hostname
     #/insights/client/<ip>/app/<category>      a category on one device
     #/insights/client/<ip>/host/<hostname>     a hostname on one device
     #/devices  #/audit  #/settings             the other tabs

   No hash lands on the overview, and so does anything this grammar does
   not read - a page is never blank because a link was mistyped. A category
   and a hostname are never nested together: the stored tables cannot cut
   one by the other, and the API refuses the pair. The category counted
   without a dictionary is the empty string, which has no path form, so it
   travels as the reserved token `no_dictionary` - the categories gate
   refuses that token as a real category id. */

// the internal tab key -> its route; "stats" keeps its key (DEC-D)
export const TAB_ROUTES = { stats: "insights", devices: "devices",
                            audit: "audit", settings: "settings" };

const NO_SCOPE = { client: null, app: null, host: null };
// a client comes first; a category or a hostname second, never both
const RANK = { client: 1, app: 2, host: 2 };

export function parseHash(hash) {
  const raw = String(hash || "").replace(/^#\/?/, "");
  const cut = raw.indexOf("?");
  const path = cut === -1 ? raw : raw.slice(0, cut);
  const query = new URLSearchParams(cut === -1 ? "" : raw.slice(cut + 1));
  const segments = path ? path.split("/") : [];
  const head = segments[0] || TAB_ROUTES.stats;
  const tab = Object.keys(TAB_ROUTES).find((key) => TAB_ROUTES[key] === head);
  const overview = { tab: "stats", scope: { ...NO_SCOPE }, range: null };
  if (!tab) return overview;
  if (tab !== "stats") return segments.length === 1 ? { ...overview, tab } : overview;
  const asked = query.get("range");
  const range = RANGES.includes(asked) ? asked : null;
  const rest = segments.slice(1);
  if (rest.length % 2) return { ...overview, range };
  const scope = { ...NO_SCOPE };
  let rank = 0;
  for (let i = 0; i < rest.length; i += 2) {
    const kind = rest[i];
    let value;
    try {
      value = decodeURIComponent(rest[i + 1]);
    } catch {
      return { ...overview, range };
    }
    // own keys only: `constructor` is not a scope (hasOwnProperty, not
    // Object.hasOwn: the build targets browsers older than ES2022)
    if (!Object.prototype.hasOwnProperty.call(RANK, kind) || RANK[kind] <= rank
        || !value) {
      return { ...overview, range };
    }
    rank = RANK[kind];
    scope[kind] = kind === "app" && value === NO_DICTIONARY ? "" : value;
  }
  return { tab, scope, range };
}

export function formatHash({ tab = "stats", scope = NO_SCOPE, range = null }) {
  if (tab !== "stats") return `#/${TAB_ROUTES[tab]}`;
  let path = `#/${TAB_ROUTES.stats}`;
  if (scope.client) path += `/client/${encodeURIComponent(scope.client)}`;
  if (scope.app !== null && scope.app !== undefined) {
    path += `/app/${encodeURIComponent(scope.app === "" ? NO_DICTIONARY : scope.app)}`;
  } else if (scope.host) {
    path += `/host/${encodeURIComponent(scope.host)}`;
  }
  return range ? `${path}?range=${encodeURIComponent(range)}` : path;
}

/* The current route and a navigate(route, {replace}) that writes it. A push
   goes through the hash so `hashchange` (back, forward, a typed URL) is the
   one path every change takes. */
export function useHashRoute() {
  const [route, setRoute] = useState(() => parseHash(window.location.hash));
  useEffect(() => {
    const follow = () => setRoute(parseHash(window.location.hash));
    window.addEventListener("hashchange", follow);
    return () => window.removeEventListener("hashchange", follow);
  }, []);
  const navigate = useCallback((next, { replace = false } = {}) => {
    const hash = formatHash(next);
    if (replace || hash === window.location.hash) {
      window.history.replaceState(null, "", hash);
      setRoute(parseHash(hash));
      return;
    }
    window.location.hash = hash;
  }, []);
  return [route, navigate];
}
