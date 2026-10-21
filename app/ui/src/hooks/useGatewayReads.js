import { useCallback, useEffect, useRef, useState } from "react";

import { api } from "../api.js";
import { CADENCE_MS, WIDGET_CADENCE_MS, isDue, normalizeRange } from "../stats.js";

/* The gateway widgets' reads (#103 DEC-D): the node delay for the view's
   range and the subscription quota - gateway-wide, sampled every 300 s and
   hourly, so read on their OWN cadence beside the overview's per-tick read
   (useScopedStats), never inside it. Each read keeps its own in-flight flag
   and generation: a slow 14-day delay read never holds the overview, nor
   the overview it.

   When a read happens:
     - at once for a path not read yet: the first gateway view (after the
       first /health answer), and the delay on a new range - which
       supersedes a read of the old range still in flight;
     - otherwise only when due - on the shell's tick, on a return to the
       page and when a scope round trip brings the gateway view back:
       every 300 s after a good answer, every 10 s until there is one and
       after a failed one;
     - never while the page is hidden, not even on open;
     - never beside one still in flight for the same path; one unanswered
       for two cadences marks the picture stale instead, until a read
       settles;
     - and at once on `refresh` (the Refresh button, a purge). A read that
       starts while another is in flight - a refresh, a new range -
       supersedes it, and the superseded request is aborted: one request on
       the wire. A refresh that cannot read now (another scope is shown, the
       page is hidden) re-arms the read for the gateway view's return; a
       purge (`{ forget: true }`) also forgets the answer, so what it
       deleted is never drawn as fresh when the gateway view comes back,
       while a plain Refresh keeps it as the last good picture.
   An answer for another range, or a superseded one, is dropped before any
   setter runs. */
function useCadencedRead({ path, enabled, tick, healthSettled }) {
  const [answer, setAnswer] = useState(null);
  const [failure, setFailure] = useState(null);
  const [pendingGen, setPendingGen] = useState(0);
  const [settled, setSettled] = useState({ gen: -1, path: null });
  const [stalled, setStalled] = useState(false);
  const generation = useRef(0);
  const inFlight = useRef(false);
  const lastFetch = useRef(0);
  // the path of the newest read started: a scope round trip brings the
  // same one back, a new range another
  const started = useRef(null);
  const controller = useRef(null);

  const load = useCallback(async () => {
    const mine = generation.current + 1;
    generation.current = mine;
    if (controller.current) controller.current.abort();
    const abort = new AbortController();
    controller.current = abort;
    inFlight.current = true;
    lastFetch.current = Date.now();
    started.current = path;
    setPendingGen(mine);
    const { status, data } = await api("GET", path, undefined, { signal: abort.signal });
    if (mine !== generation.current) return;
    controller.current = null;
    inFlight.current = false;
    setStalled(false);
    if (status === 200 && data) {
      setAnswer({ path, data, at: `${new Date().toISOString().slice(0, 19)}Z` });
      setFailure(null);
    } else {
      setFailure({ path, reason: status === 0 ? "unreachable" : "unavailable" });
    }
    setSettled({ gen: mine, path });
  }, [path]);

  const current = answer && answer.path === path ? answer : null;
  const failing = Boolean(failure && failure.path === path);
  // a failed refresh retries at the minute cadence, like a first read:
  // one lost answer must not leave the widget stale for five minutes
  const cadence = current && !failing ? WIDGET_CADENCE_MS : CADENCE_MS.minute;
  const fetchIfDue = useCallback(() => {
    if (!enabled || !healthSettled || document.hidden) return;
    if (started.current !== path) {
      load();
      return;
    }
    const elapsed = Date.now() - lastFetch.current;
    if (inFlight.current) {
      if (isDue(elapsed, 2 * cadence)) setStalled(true);
      return;
    }
    if (isDue(elapsed, cadence)) load();
  }, [enabled, healthSettled, path, cadence, load]);

  // a new input (the view opening, a new range, a return from another
  // scope) asks the same question the tick does: is a read due?
  useEffect(() => { fetchIfDue(); }, [fetchIfDue]);
  const dueCheck = useRef(fetchIfDue);
  useEffect(() => { dueCheck.current = fetchIfDue; }, [fetchIfDue]);
  useEffect(() => { if (tick) dueCheck.current(); }, [tick]);
  useEffect(() => {
    const onVisible = () => dueCheck.current();
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, []);

  // unmounting: nothing still on the wire, nothing set after - and nothing
  // left marked in flight, so a remount (StrictMode's in development) reads
  useEffect(() => () => {
    generation.current += 1;
    if (controller.current) controller.current.abort();
    controller.current = null;
    inFlight.current = false;
    started.current = null;
  }, []);

  // a refresh runs after a confirm and a POST: it reads the scope shown
  // THEN, never the one its caller captured when the button was pressed
  const now = useRef({ enabled, healthSettled, load });
  useEffect(() => { now.current = { enabled, healthSettled, load }; });
  const refresh = useCallback(({ forget = false } = {}) => {
    const live = now.current;
    if (live.enabled && live.healthSettled && !document.hidden) return live.load();
    started.current = null;
    if (forget) {
      generation.current += 1;
      if (controller.current) controller.current.abort();
      controller.current = null;
      inFlight.current = false;
      setPendingGen(generation.current);
      setAnswer(null);
      setFailure(null);
      setStalled(false);
    }
    return Promise.resolve();
  }, []);

  return {
    data: current ? current.data : null,
    at: current ? current.at : "",
    failed: failure && failure.path === path ? failure.reason : null,
    stalled: current ? stalled : false,
    ready: settled.gen === pendingGen && settled.path === path,
    refresh,
  };
}

export default function useGatewayReads({ enabled, range, tick, healthSettled }) {
  const delay = useCadencedRead({
    path: `/v1/stats/node-delay?range=${normalizeRange(range)}`,
    enabled, tick, healthSettled });
  const quota = useCadencedRead({ path: "/v1/stats/quota", enabled, tick,
                                  healthSettled });
  const refreshDelay = delay.refresh;
  const refreshQuota = quota.refresh;
  // a purge deletes what both widgets draw: they must re-read at once, not
  // keep showing deleted figures as fresh until their next due read
  const refresh = useCallback((options) => Promise.all([refreshDelay(options),
                                                       refreshQuota(options)]),
                              [refreshDelay, refreshQuota]);
  return { delay, quota, refresh };
}
