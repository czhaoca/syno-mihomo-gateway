import { useState } from "react";
import Box from "@mui/material/Box";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";

import TimeSeries from "../../charts/TimeSeries.jsx";
import useLiveStream, { LIVE_FRAMES, STALE_AFTER_S, liveChosen,
                       rememberLive } from "../../hooks/useLiveStream.js";
import { fmtBytes } from "../../stats.js";

/* The live throughput tile (#103 DEC-F): OFF until this browser opts in
   (a native checkbox, remembered per browser - DEC-A), then the gateway's
   bytes per second, now and over the last minute. Nothing from it is
   stored, and the tile says so whatever its state. The rates and the
   sparkline are shown only while the stream is live: when it goes quiet
   they give way to how long it has been, and when it closes to why - never
   a frozen picture shown as current. */
export default function LiveTile({ t }) {
  const [on, setOn] = useState(liveChosen);
  const stream = useLiveStream(on);
  const toggle = (event) => {
    rememberLive(event.target.checked);
    setOn(event.target.checked);
  };
  const live = stream.state === "live" && stream.staleS === null && stream.latest;
  return (
    <Box data-testid="live-tile" sx={{ border: 1, borderColor: "divider",
                                       borderRadius: 1.5, p: 1.25, minWidth: 0 }}>
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
        <Box component="label" sx={{ display: "inline-flex", alignItems: "center",
                                     gap: 0.75, minHeight: 44, cursor: "pointer" }}>
          <input type="checkbox" data-testid="live-toggle" checked={on}
                 onChange={toggle} style={{ width: 20, height: 20 }} />
          <Typography variant="subtitle2" component="span">{t("live_toggle")}</Typography>
        </Box>
        <Typography variant="caption" color="text.secondary" data-testid="live-not-stored">
          {t("live_not_stored")}
        </Typography>
      </Stack>
      {on ? (
        <Stack spacing={0.75} sx={{ mt: 0.75 }}>
          {stream.state === "full" || stream.state === "closed" ? (
            <Typography variant="body2" color="warning.main" data-testid="live-closed">
              {stream.state === "full" ? t("live_full") : t("live_closed")}
            </Typography>
          ) : stream.staleS !== null ? (
            <Typography variant="body2" color="warning.main" data-testid="live-stale"
                        data-seconds={stream.staleS}>
              {`${t("live_stale")} ${stream.staleS}s`}
            </Typography>
          ) : live ? (
            <Box data-testid="live-rates" sx={{ display: "flex", gap: 2, flexWrap: "wrap" }}>
              <Typography variant="h6" data-testid="live-rate-up"
                          data-bps={stream.latest.up_bps}>
                {`${t("col_up")} ${fmtBytes(stream.latest.up_bps)}/s`}
              </Typography>
              <Typography variant="h6" data-testid="live-rate-down"
                          data-bps={stream.latest.down_bps}>
                {`${t("col_down")} ${fmtBytes(stream.latest.down_bps)}/s`}
              </Typography>
            </Box>
          ) : (
            <Typography variant="body2" color="text.secondary" data-testid="live-connecting">
              {t("live_connecting")}
            </Typography>
          )}
          {live ? (
            <TimeSeries grid={minuteGrid(stream.frames, t)} testid="live-sparkline" t={t}
                        height={48} compact unit="bps" />
          ) : null}
        </Stack>
      ) : null}
    </Box>
  );
}

/* The last minute on one-second slots. Frames come about once a second,
   stamped to the whole second, so two can share a stamp and one can skip
   one: a frame up to STALE_AFTER_S - 1 seconds after the one before takes
   the next slot. A longer silence - the one the tile calls stale - is a
   HOLE, the kit's hatched value-less mark (in this kit a blank between bars
   reads as zero), so the frames after a reconnect never sit beside the
   ones before it as if the stream had not stopped. */
function minuteGrid(frames, t) {
  const placed = [];
  let prev = null;
  for (const f of frames) {
    const at = Date.parse(f.ts);
    if (!Number.isFinite(at)) continue;
    const step = prev === null ? 0 : Math.round((at - prev.at) / 1000);
    const x = prev === null ? 0 : prev.x + (step >= STALE_AFTER_S ? step : 1);
    // two frames can share a stamp: each is known by its arrival number,
    // which stays its own as the minute slides
    placed.push({ f, at, x, id: `frame-${f.seq}`, ts: f.ts });
    prev = { at, x };
  }
  const start = placed.length ? placed[placed.length - 1].x - (LIVE_FRAMES - 1) : 0;
  const cells = [];
  placed.forEach(({ f, x, id }, i) => {
    const before = i ? placed[i - 1].x : null;
    if (before !== null && x - before > 1 && x - 1 >= start) {
      const from = Math.max(before + 1, start);
      cells.push({ key: f.ts, id: `hole|${id}`, label: `${placed[i - 1].ts} - ${f.ts}`,
                   note: t("live_hole"),
                   x: from - start, width: x - from, up: 0, down: 0,
                   held: false, gap: "full", seam: false });
    }
    if (x >= start) {
      cells.push({ key: f.ts, id, x: x - start, width: 1, up: f.up_bps, down: f.down_bps,
                   held: true, gap: "", seam: false });
    }
  });
  return {
    tier: "live", units: LIVE_FRAMES,
    max: Math.max(0, ...cells.map((c) => c.up + c.down)),
    before: null, stale: null, shade: null, axisStart: null, axisEnd: null, cells,
  };
}
