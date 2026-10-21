import Box from "@mui/material/Box";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";
import { useTheme } from "@mui/material/styles";

import ChartFrame from "../../charts/ChartFrame.jsx";
import { fmtBytes } from "../../stats.js";

/* The subscription quota widget (#103 DEC-G): for each provider that
   reports one, what it says has been used against its total, when it
   expires, and when the provider last reported it. mihomo zero-fills a
   number the provider did not send, so an unknown total or expiry arrives
   as null - then there is no bar and no percentage, only "not reported".
   The text gives the true share (an overrun reads as one); only the bar is
   capped at full.

   The frame draws stored figures only: fresh after a good sample, stale -
   since the last good sample - when mihomo did not answer it (which a note
   says), a read failed or hangs, or the collector stopped. With nothing
   stored it is empty when no provider reports a quota, and otherwise left
   to the "not sampled yet" and "collector stopped" notes: a stale label
   over nothing would claim figures that were never kept. */
export default function Quota({ t, read, collecting }) {
  const chart = useTheme().palette.chart;
  const body = read.data;
  const providers = body ? body.providers : [];
  // as for the node delay: a failed or hung refresh over an answer with
  // nothing stored is stale, never a current-looking "none"
  const refreshed = !read.failed && !read.stalled;
  let state = null;
  if (body) {
    if (providers.length) {
      state = body.state === "ok" && refreshed && collecting ? "fresh" : "stale";
    } else if (!refreshed) {
      state = "stale";
    } else if (body.state === "none" || body.state === "ok") {
      state = "empty";
    }
  } else if (read.failed) {
    state = "unavailable";
  }
  const reported = providers.reduce((top, q) => (q.updatedAt && q.updatedAt > top
    ? q.updatedAt : top), "");
  const now = Date.now();
  return (
    <Stack spacing={0.75} data-testid="quota" sx={{ minWidth: 0 }}>
      {read.ready ? <span data-testid="quota-ready" hidden /> : null}
      <Typography variant="subtitle2">{t("quota_title")}</Typography>
      {body && body.state === "pending" ? (
        <Typography variant="body2" color="text.secondary" data-testid="quota-pending">
          {t("quota_pending")}
        </Typography>
      ) : null}
      {body && body.state === "error" ? (
        <Typography variant="body2" color="warning.main" data-testid="quota-error">
          {t("quota_error")}
        </Typography>
      ) : null}
      {body && body.state === "off" ? (
        <Typography variant="body2" color="text.secondary" data-testid="quota-off">
          {t("quota_off")}
        </Typography>
      ) : null}
      <ChartFrame id="quota-frame" state={state}
                  since={(body && body.sampled_at) || reported || read.at || "-"}
                  reason={read.failed || ""} t={t}
                  emptyText={t("quota_none")}
                  staleText={providers.length ? t("quota_stale") : t("quota_stale_empty")}
                  unavailableText={t("quota_unavailable")}>
        <Stack spacing={1}>
          {body && body.state === "none" && !providers.length ? (
            <Typography variant="body2" color="text.secondary" data-testid="quota-none-stored">
              {t("quota_none")}
            </Typography>
          ) : null}
          {providers.map((q, i) => {
            // a share needs both halves: never a percentage from a null
            const used = q.upload === null || q.download === null ? null
              : q.upload + q.download;
            const share = used !== null && q.total ? (used / q.total) * 100 : null;
            const expired = q.expire !== null && q.expire * 1000 < now;
            return (
              <Box key={`${q.provider}:${i}`} data-testid={`quota-row-${i}`}
                   data-provider={q.provider} sx={{ minWidth: 0 }}>
                <Typography variant="body2" sx={{ fontWeight: 600, overflowWrap: "anywhere" }}>
                  {q.provider}
                </Typography>
                {share !== null ? (
                  <>
                    <Box data-testid={`quota-bar-${i}`} data-share={share.toFixed(1)}
                         sx={{ height: 10, borderRadius: 1, overflow: "hidden",
                               bgcolor: chart.grid, border: 1, borderColor: chart.border }}>
                      <Box sx={{ width: `${Math.min(100, share)}%`, height: "100%",
                                 bgcolor: chart.up }} />
                    </Box>
                    <Typography variant="body2" data-testid={`quota-used-${i}`}
                                color={share > 100 ? "warning.main" : "text.secondary"}>
                      {`${fmtBytes(used)} / ${fmtBytes(q.total)} (${share.toFixed(1)}%)`}
                    </Typography>
                  </>
                ) : q.total !== null ? (
                  <Typography variant="body2" color="text.secondary"
                              data-testid={`quota-no-used-${i}`}>
                    {`${t("quota_limit")} ${fmtBytes(q.total)} - ${t("quota_used_unknown")}`}
                  </Typography>
                ) : (
                  <Typography variant="body2" color="text.secondary"
                              data-testid={`quota-no-limit-${i}`}>
                    {used !== null ? `${t("quota_used")} ${fmtBytes(used)} - ` : ""}
                    {t("quota_no_limit")}
                  </Typography>
                )}
                <Typography variant="caption" color={expired ? "warning.main" : "text.secondary"}
                            data-testid={`quota-expire-${i}`}
                            data-expired={expired ? "true" : "false"} sx={{ display: "block" }}>
                  {q.expire !== null
                    ? `${expired ? t("quota_expired") : t("quota_expires")} ${
                      new Date(q.expire * 1000).toISOString().slice(0, 10)}`
                    : t("quota_no_expire")}
                  {" - "}
                  <Box component="span" sx={{ whiteSpace: "nowrap" }}>
                    {q.updatedAt ? `${t("quota_updated")} ${q.updatedAt}` : t("quota_updated_unknown")}
                  </Box>
                </Typography>
              </Box>
            );
          })}
        </Stack>
      </ChartFrame>
    </Stack>
  );
}
