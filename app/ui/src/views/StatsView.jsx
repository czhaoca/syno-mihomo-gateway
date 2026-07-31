import { useCallback, useEffect, useRef, useState } from "react";
import Button from "@mui/material/Button";
import Stack from "@mui/material/Stack";
import Table from "@mui/material/Table";
import TableBody from "@mui/material/TableBody";
import TableCell from "@mui/material/TableCell";
import TableContainer from "@mui/material/TableContainer";
import TableHead from "@mui/material/TableHead";
import TableRow from "@mui/material/TableRow";
import Typography from "@mui/material/Typography";

import { api } from "../api.js";
import { SelectInput, Sparkline } from "../controls.jsx";
import {
  RANGES, aliasMap, coveragePath, fmtBytes, labelFor, normalizeRange, statsPath,
} from "../stats.js";

/* The landing view (#80).

   Every note here reports the measurement's OWN honesty rather than a bare
   number, which is the standard the rest of the epic set: collection gaps
   are shown as holes and never interpolated, a day window says when its
   boundary moved inside it, and the attribution share says how far back it
   could actually see. A percentage with no window attached is the kind of
   quiet inaccuracy a blocking decision must not rest on.

   Every fetch follows the classic tree's rule: a failed sub-request may not
   retract what is on screen. Only a good answer changes a claim, because a
   transient failure says nothing about whether the previous claim is still
   true. */

export default function StatsView({ t, notify, tick }) {
  const [range, setRange] = useState(null);
  const [rows, setRows] = useState([]);
  const [timeline, setTimeline] = useState([]);
  const [aliases, setAliases] = useState(() => new Map());
  const [gaps, setGaps] = useState(null);
  const [domainsOff, setDomainsOff] = useState(false);
  const [framings, setFramings] = useState([]);
  const [coverage, setCoverage] = useState(null);
  // null once a good answer is in hand; otherwise WHY there is nothing to
  // show. "No traffic in this range" and "the stats store did not answer"
  // look identical on screen and mean opposite things, and only one of them
  // is a statement about the network.
  const [problem, setProblem] = useState(null);

  /* Monotonic request id, as in AuditView. A slow answer for an ABANDONED
     window must never repaint over a newer one, or the selector and the
     numbers beside it name different windows with nothing saying so.

     This is not hypothetical ordering paranoia: switching 48h (a minute-tier
     aggregation, the heaviest query the panel issues) to daily (a small one
     with no `since` at all) reliably lands the older answer last. */
  const generation = useRef(0);

  /* The settings-backed default (DEC-A). The view paints IMMEDIATELY at the
     shipped default and corrects itself if the operator's stored preference
     differs - it never blocks on this call. `/v1/settings` reads policy.db
     while every stats route reads the separate stats.db, so gating the
     landing tab on it would invent a dependency the storage layer was
     deliberately built without. */
  useEffect(() => {
    let live = true;
    api("GET", "/v1/settings").then(({ status, data }) => {
      if (!live || status !== 200 || !data || !data.settings) return;
      const stored = data.settings.stats_default_range;
      if (stored && stored.value) setRange(normalizeRange(stored.value));
    });
    return () => { live = false; };
  }, []);

  const effective = normalizeRange(range || undefined);

  const load = useCallback(async () => {
    const mine = generation.current + 1;
    generation.current = mine;
    const [devices, line, gapRows, domains, ids, cover] = await Promise.all([
      api("GET", statsPath("/v1/stats/devices", effective)),
      api("GET", statsPath("/v1/stats/timeline", effective)),
      api("GET", "/v1/stats/gaps"),
      api("GET", "/v1/stats/domains"),
      api("GET", "/v1/identity"),
      // The SELECTED window, not the endpoint default. Attribution is capped
      // at 7 days by construction, so asking for 30 cannot widen it - but it
      // makes the server report `truncated`, which is the difference between
      // a percentage that answers the question on screen and one that
      // quietly answers a different one.
      api("GET", coveragePath(effective)),
    ]);
    // Superseded: drop it silently rather than repaint. The check sits BEFORE
    // every setter, including the one below - a stale batch must not even flip
    // the failure flag.
    if (mine !== generation.current) return;
    setProblem(devices.status === 200 ? null
      : devices.status === 0 ? "unreachable" : "unavailable");
    if (devices.status === 200) {
      setRows(devices.data.rows || []);
      // Present only on the day tier, and more than one means the window is
      // a union of differently-defined days rather than a single 24h one.
      setFramings(devices.data.framings || []);
    }
    if (line.status === 200) setTimeline(line.data.rows || []);
    if (ids.status === 200) setAliases(aliasMap(ids.data.identities));
    if (gapRows.status === 200) setGaps(gapRows.data.rows || []);
    if (domains.status === 200) setDomainsOff(domains.data.enabled === false);
    if (cover.status === 200) setCoverage(cover.data);
  }, [effective]);

  useEffect(() => { load(); }, [load, tick]);

  const purge = async () => {
    if (!window.confirm(t("purge_confirm"))) return;
    const result = await api("POST", "/v1/stats/purge");
    if (result.status === 200) await load();
    else if (result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
  };

  const attributable = coverage
    ? (coverage.classes || []).find((c) => c.klass === "hostname")
    : null;

  return (
    <Stack spacing={1.5}>
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap"
             useFlexGap>
        <SelectInput
          data-testid="stats-range"
          value={effective}
          onChange={(e) => setRange(e.target.value)}
        >
          {RANGES.map((r) => (
            <option key={r} value={r}>{t(`range_${r}`)}</option>
          ))}
        </SelectInput>
        <Button data-testid="stats-refresh" onClick={load}>{t("refresh")}</Button>
        <Button data-testid="stats-purge" color="error" onClick={purge}>
          {t("purge_stats")}
        </Button>
      </Stack>

      <Sparkline rows={timeline} testid="stats-sparkline" />

      <TableContainer sx={{ overflowX: "auto" }}>
        <Table size="small" data-testid="stats-table">
          <TableHead>
            <TableRow>
              <TableCell>{t("col_device")}</TableCell>
              <TableCell align="right">{t("col_up")}</TableCell>
              <TableCell align="right">{t("col_down")}</TableCell>
            </TableRow>
          </TableHead>
          <TableBody data-testid="stats-rows">
            {rows.map((row) => (
              <TableRow key={row.device}>
                <TableCell sx={{ whiteSpace: "nowrap",
                                 fontFamily: "ui-monospace, monospace" }}>
                  {labelFor(row.device, aliases)}
                </TableCell>
                <TableCell align="right">{fmtBytes(row.up)}</TableCell>
                <TableCell align="right">{fmtBytes(row.down)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>

      {rows.length === 0 ? (
        <Typography variant="body2"
                    color={problem ? "warning.main" : "text.secondary"}
                    data-testid="stats-empty">
          {problem === "unreachable" ? t("stats_unreachable")
            : problem === "unavailable" ? t("stats_unavailable")
              : t("stats_empty")}
        </Typography>
      ) : null}

      {framings.length > 1 ? (
        <Typography variant="body2" color="warning.main" data-testid="framings-note">
          {`${t("framings_note")}: ${framings
            .map((f) => `${f.bucket_tz} ${f.day_boundary}`).join(", ")}`}
        </Typography>
      ) : null}

      {attributable ? (
        <Typography variant="body2" color="text.secondary" data-testid="coverage-note">
          {`${t("coverage_note")}: ${attributable.share.toFixed(1)}% `
           + `(${t("coverage_window")}: ${coverage.window.retention_days}d)`}
          {coverage.window.truncated ? ` — ${t("coverage_truncated")}` : ""}
        </Typography>
      ) : null}

      {gaps && gaps.length ? (
        <Typography variant="body2" color="warning.main" data-testid="gaps-note">
          {`${t("gaps_note")}: ${gaps.length}`}
        </Typography>
      ) : null}

      {domainsOff ? (
        <Typography variant="body2" color="text.secondary" data-testid="domains-note">
          {t("domains_off")}
        </Typography>
      ) : null}
    </Stack>
  );
}
