import { useCallback, useEffect, useRef, useState } from "react";

import { api } from "../api.js";
import { CADENCE_MS, isDue, overviewPath, resolutionOf } from "../stats.js";

/* The one stats read Gateway Insights makes (#101 DEC-E/H): the scoped
   `/v1/stats/overview`, whose every section comes from one read
   transaction and so describes the same moment.

   When it fetches:
     - at once, for a new input (range, scope, list size) - superseding any
       read in flight, whose answer is then dropped (a generation counter);
     - on the shell's tick only when DUE: the cadence of the answer's own
       resolution has passed (10 s minute, 60 s hour, 300 s day - give or
       take half a tick, so the tick's own jitter never skips one), the page
       is visible, and no read is in flight - a slow server is never piled
       on;
     - when the page becomes visible again, if due;
     - until a view has its first answer, at the minute cadence;
     - never before the first /health answer has settled (see linePoll).

   A read unanswered for two cadences is never joined by a second one; the
   view is marked `stalled` instead, so the picture says it is stale.

   What it keeps, from the chart kit's rules (#100):
     - `linePoll`: the collector's last poll as /health reported it when the
       read STARTED - a poll the answer is known to include. /health keeps
       advancing while reads fail; the grid zero-fills only up to this.
     - a failed refresh keeps the last answer for the same view, marked
       stale; it never retracts it.
     - the answer of another view (range or scope) is never shown as this
       one's; a bigger list of the same view is, until its own answer lands.

   `ready` is the readiness marker's condition: the newest read for the
   current input has settled, good or failed. */
export default function useScopedStats({ range, scope, limit, tick, health,
                                         healthSettled }) {
  const path = overviewPath(range, scope, limit);
  // the view an answer belongs to: the same range and scope at any size
  const view = overviewPath(range, scope, 0);
  const [answer, setAnswer] = useState(null);
  const [failure, setFailure] = useState(null);
  const [linePoll, setLinePoll] = useState(null);
  const [lastGood, setLastGood] = useState("");
  const [pendingGen, setPendingGen] = useState(0);
  const [settled, setSettled] = useState(() => ({ gen: -1, path: null,
                                                  at: Date.now() }));
  // the read in flight has gone unanswered for two cadences: the picture on
  // screen is no longer a measurement of now
  const [stalled, setStalled] = useState(false);
  const generation = useRef(0);
  const inFlight = useRef(false);
  const lastFetch = useRef(0);
  const healthRef = useRef(health);
  useEffect(() => { healthRef.current = health; }, [health]);

  const load = useCallback(async () => {
    const mine = generation.current + 1;
    generation.current = mine;
    inFlight.current = true;
    lastFetch.current = Date.now();
    setPendingGen(mine);
    setStalled(false);
    const seen = healthRef.current;
    const polled = seen ? seen.collector_last_ts || null : null;
    const { status, data } = await api("GET", path);
    // superseded: drop it before ANY setter, the failure flag included
    if (mine !== generation.current) return;
    inFlight.current = false;
    // the stall described THIS read; it is answered now
    setStalled(false);
    if (status === 200 && data) {
      setAnswer({ view, data });
      setLinePoll(polled);
      setFailure(null);
      setLastGood(`${new Date().toISOString().slice(0, 19)}Z`);
    } else {
      setFailure({ view, reason: status === 0 ? "unreachable" : "unavailable" });
    }
    setSettled({ gen: mine, path, at: Date.now() });
  }, [path, view]);

  const current = answer && answer.view === view ? answer.data : null;
  // until this view has an answer, it retries at the minute cadence: a
  // failed first read of a day view must not wait five minutes
  const tier = current
    ? (current.timeline && current.timeline.tier) || resolutionOf(range)
    : "minute";
  const cadence = CADENCE_MS[tier] || CADENCE_MS.minute;
  const fetchIfDue = useCallback(() => {
    if (!healthSettled || document.hidden) return;
    const elapsed = Date.now() - lastFetch.current;
    if (inFlight.current) {
      // never a second read beside it - but say the picture is stale
      if (isDue(elapsed, 2 * cadence)) setStalled(true);
      return;
    }
    if (isDue(elapsed, cadence)) load();
  }, [healthSettled, cadence, load]);

  // a new input, or the first /health answer: read at once
  useEffect(() => { if (healthSettled) load(); }, [load, healthSettled]);
  // the shell's tick and a return to the page: only when due. Both reach
  // the newest check through a ref, so a new input (a new fetchIfDue) never
  // re-runs them - only a tick or a visibility change does
  const dueCheck = useRef(fetchIfDue);
  useEffect(() => { dueCheck.current = fetchIfDue; }, [fetchIfDue]);
  useEffect(() => { if (tick) dueCheck.current(); }, [tick]);
  useEffect(() => {
    const onVisible = () => dueCheck.current();
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, []);

  return {
    data: current,
    failed: failure && failure.view === view ? failure.reason : null,
    stalled,
    linePoll: current ? linePoll : null,
    lastGood,
    settledAt: settled.at,
    ready: settled.gen === pendingGen && settled.path === path,
    refresh: load,
  };
}
