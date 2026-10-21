import Box from "@mui/material/Box";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";

import ChartFrame from "../../charts/ChartFrame.jsx";
import TimeSeries from "../../charts/TimeSeries.jsx";
import { delayGrid } from "../../charts/grid.js";

/* The node delay widget (#103 DEC-H): for each policy group, the node it
   has selected and how that node answered mihomo's own tests over the
   view's range - one row and one strip per group. A failed test is "no
   answer", hatched, never 0 ms; a stretch with no test is blank. The frame
   says when the picture cannot be trusted: unavailable only when this
   range has no answer at all, stale after a failed refresh or while the
   collector is down, empty (in delay words, never traffic ones) when no
   test is stored yet. `latest` is the group's newest stored test, which
   can predate the window: its time is always shown. */
export default function NodeDelay({ t, read, range, collecting }) {
  const body = read.data;
  let state = null;
  // nothing stored is a fact the newest read can state even while the
  // collector is down - but not one a failed or hung refresh can: that is
  // stale, the last answer's "nothing stored" kept under it
  const refreshed = !read.failed && !read.stalled;
  if (body) {
    if (!body.groups.length) state = refreshed ? "empty" : "stale";
    else state = refreshed && collecting ? "fresh" : "stale";
  } else if (read.failed) {
    state = "unavailable";
  }
  const now = read.at ? Date.parse(read.at) : Date.now();
  // stale since the newest stored test, not since the read that carried it:
  // a stopped collector stops the tests, the reads go on answering
  const newest = body ? body.groups.reduce((top, g) => (g.latest
    && g.latest.tested_at > top ? g.latest.tested_at : top), "") : "";
  return (
    <Stack spacing={0.75} data-testid="node-delay" sx={{ minWidth: 0 }}>
      {read.ready ? <span data-testid="node-delay-ready" data-range={range} hidden /> : null}
      <Typography variant="subtitle2">{t("delay_title")}</Typography>
      <ChartFrame id="node-delay-frame" state={state} since={newest || read.at || "-"}
                  reason={read.failed || ""} t={t}
                  emptyText={t("delay_empty")} staleText={t("delay_stale")}
                  unavailableText={t("delay_unavailable")}>
        <Stack spacing={1.25}>
          {body && !body.groups.length ? (
            <Typography variant="body2" color="text.secondary"
                        data-testid="node-delay-none-stored">
              {t("delay_empty")}
            </Typography>
          ) : null}
          {body && body.truncated ? (
            <Typography variant="body2" color="text.secondary"
                        data-testid="node-delay-truncated">
              {`${t("delay_kept")} ${body.retention_days}d - ${t("delay_since")} ${body.since}`}
            </Typography>
          ) : null}
          {(body ? body.groups : []).map((group, i) => (
            <Box key={`${group.group}:${i}`} data-testid={`node-delay-row-${i}`}
                 data-group={group.group} sx={{ minWidth: 0 }}>
              <Box sx={{ display: "flex", flexWrap: "wrap", columnGap: 1,
                         alignItems: "baseline", minWidth: 0 }}>
                <Typography variant="body2" sx={{ fontWeight: 600, overflowWrap: "anywhere" }}>
                  {group.group}
                </Typography>
                {group.latest ? (
                  <Typography variant="body2" color="text.secondary"
                              data-testid={`node-delay-${i}-latest`}
                              data-ms={group.latest.delay_ms ?? undefined}
                              sx={{ overflowWrap: "anywhere" }}>
                    {`${group.latest.node}: ${group.latest.delay_ms === null
                      ? t("delay_no_answer") : `${group.latest.delay_ms} ms`}`}
                    <Box component="span" sx={{ whiteSpace: "nowrap", ml: 0.75 }}>
                      {`${t("delay_as_of")} ${group.latest.tested_at}`}
                    </Box>
                  </Typography>
                ) : (
                  <Typography variant="body2" color="text.secondary"
                              data-testid={`node-delay-${i}-latest`}>
                    {t("delay_none_yet")}
                  </Typography>
                )}
              </Box>
              {group.points.length ? (
                <TimeSeries testid={`node-delay-${i}`} t={t} unit="ms" compact
                            height={44}
                            grid={delayGrid({ points: group.points,
                                              resolution: body.resolution,
                                              since: body.since,
                                              sampledEveryS: body.sampled_every_s,
                                              now })} />
              ) : (
                <Typography variant="caption" color="text.secondary"
                            data-testid={`node-delay-${i}-none`}>
                  {t("delay_no_test_window")}
                </Typography>
              )}
            </Box>
          ))}
        </Stack>
      </ChartFrame>
    </Stack>
  );
}
