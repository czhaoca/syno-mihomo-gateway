import { useEffect, useRef, useState } from "react";

/* The live throughput stream (#103 DEC-F): one EventSource to
   /v1/stats/live while ON and the page is visible - closed when the page
   hides, when ON goes false and when the tile unmounts, so a panel nobody
   looks at holds no stream (and the panel then reads none from mihomo).
   Frames are kept for the sparkline, the last LIVE_FRAMES only, in memory:
   nothing from the stream is stored.

   `staleS` is how long it has been since the last DATA frame (a `: ping`
   is not one) once that passes STALE_AFTER_S - the tile shows it instead of
   the old numbers, never a frozen rate as if it were current. `full` (the
   panel has too many live viewers) and a stream the browser gave up on
   close it for good; toggling off and on tries again. */
export const LIVE_FRAMES = 60;
export const STALE_AFTER_S = 3;

// the per-browser toggle (DEC-A): off unless this browser opted in
const LIVE_KEY = "panel_live";

export function liveChosen() {
  try {
    return localStorage.getItem(LIVE_KEY) === "1";
  } catch {
    return false;
  }
}

export function rememberLive(on) {
  try {
    localStorage.setItem(LIVE_KEY, on ? "1" : "0");
  } catch {
    // storage unavailable: the choice lasts for this page only
  }
}

export default function useLiveStream(on) {
  // each frame's identity in the sparkline: two can share a stamp, and the
  // minute slides, so neither the stamp nor a position can be one
  const seq = useRef(0);
  const [frames, setFrames] = useState([]);
  const [state, setState] = useState("off");
  const [lastAt, setLastAt] = useState(0);
  const [now, setNow] = useState(() => Date.now());
  const [visible, setVisible] = useState(() => !document.hidden);

  useEffect(() => {
    const follow = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", follow);
    return () => document.removeEventListener("visibilitychange", follow);
  }, []);

  useEffect(() => {
    if (!on || !visible) {
      // nothing from before a pause may come back as current on return
      setFrames([]);
      setState(on ? "paused" : "off");
      return undefined;
    }
    const source = new EventSource("/v1/stats/live");
    const opened = Date.now();
    // a new stream starts a new minute: frames from before a pause would
    // sit in the sparkline - and in the rates - as if they were current
    setFrames([]);
    setState("connecting");
    setLastAt(opened);
    source.onmessage = (event) => {
      let frame;
      try {
        frame = JSON.parse(event.data);
      } catch {
        return;
      }
      if (!frame || typeof frame.ts !== "string" || !Number.isFinite(frame.up_bps)
          || !Number.isFinite(frame.down_bps)) {
        return;
      }
      seq.current += 1;
      const numbered = { ...frame, seq: seq.current };
      setFrames((prev) => [...prev, numbered].slice(-LIVE_FRAMES));
      setLastAt(Date.now());
      setState("live");
    };
    source.addEventListener("full", () => {
      source.close();
      setState("full");
    });
    source.onerror = () => {
      // the browser retries on its own; CLOSED means it has given up (a
      // 503, a non-stream answer) - say so rather than spin
      if (source.readyState === EventSource.CLOSED) setState("closed");
    };
    return () => source.close();
  }, [on, visible]);

  useEffect(() => {
    if (!on) return undefined;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [on]);

  const since = Math.floor((now - lastAt) / 1000);
  const open = state === "live" || state === "connecting";
  return {
    state,
    frames,
    latest: frames.length ? frames[frames.length - 1] : null,
    staleS: open && since >= STALE_AFTER_S ? since : null,
  };
}
