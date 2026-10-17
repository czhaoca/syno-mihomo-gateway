import { useCallback, useEffect, useMemo, useRef, useState } from "react";
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
import ChartFrame from "../charts/ChartFrame.jsx";
import ShareBar from "../charts/ShareBar.jsx";
import TimeSeries from "../charts/TimeSeries.jsx";
import TopBars from "../charts/TopBars.jsx";
import { buildGrid } from "../charts/grid.js";
import { SelectInput } from "../controls.jsx";
import {
  GAPS_LIMIT, RANGES, aliasMap, coveragePath, fmtBytes, gapsPath, labelFor,
  normalizeRange, statsPath, windowStart,
} from "../stats.js";

/* The landing view (#80), drawn with the chart kit since #100.

   Every note here reports the measurement's OWN honesty rather than a bare
   number, which is the standard the rest of the epic set: collection gaps
   are shown as holes and never interpolated, a day window says when its
   boundary moved inside it, and the attribution share says how far back it
   could actually see. A percentage with no window attached is the kind of
   quiet inaccuracy a blocking decision must not rest on.

   Every fetch follows the classic tree's rule: a failed sub-request may not
   retract what is on screen. Only a good answer changes a claim, because a
   transient failure says nothing about whether the previous claim is still
   true - the chart then says it is stale instead. */

const TOP_N = 10;

// the dictionary's partition (#97), "unattributed" permanent; the
// hostname/ip_only one for a panel that does not report it
const DICTIONARY_TONES = { app: "up", coarse: "down",
                           unattributed: "unattributed", no_dictionary: "seam" };
const COVERAGE_TONES = { hostname: "up", ip_only: "unattributed" };

export default function StatsView({ t, notify, tick, health, healthSettled }) {
  const [range, setRange] = useState(null);
  const [rows, setRows] = useState([]);
  const [timeline, setTimeline] = useState([]);
  const [lineTier, setLineTier] = useState("hour");
  const [aliases, setAliases] = useState(() => new Map());
  const [gaps, setGaps] = useState(null);
  const [gapsFor, setGapsFor] = useState(null);
  const [domainsOff, setDomainsOff] = useState(false);
  const [framings, setFramings] = useState([]);
  const [coverage, setCoverage] = useState(null);
  const [coverageFor, setCoverageFor] = useState(null);
  // null once a good answer is in hand; otherwise WHY there is nothing to
  // show. "No traffic in this range" and "the stats store did not answer"
  // look identical on screen and mean opposite things, and only one of them
  // is a statement about the network.
  const [problem, setProblem] = useState(null);
  // the range the device rows and the timeline on screen belong to, and the
  // range whose newest load has settled (good or failed)
  const [rowsFor, setRowsFor] = useState(null);
  const [lineFor, setLineFor] = useState(null);
  const [settledFor, setSettledFor] = useState(null);
  const [settingsSettled, setSettingsSettled] = useState(false);
  // the last refresh of the timeline failed after a good answer: keep it,
  // say since when it is stale
  const [lineFailed, setLineFailed] = useState(null);
  const [failedFor, setFailedFor] = useState(null);
  const [lastGood, setLastGood] = useState("");
  // the collector's last poll as /health reported it BEFORE the timeline on
  // screen was read - a poll that data is known to include. /health keeps
  // advancing while a refresh fails; read from it directly, the grid would
  // fill every bucket after the last good read with zeros nobody measured.
  const [linePoll, setLinePoll] = useState(null);
  const healthRef = useRef(health);
  useEffect(() => { healthRef.current = health; }, [health]);
  // the load generation in flight and the newest one settled: the view is
  // ready only when they are the same one (a refresh in flight is not)
  const [pendingGen, setPendingGen] = useState(0);
  const [settledGen, setSettledGen] = useState(-1);
  // "now" for the axis: when the newest load settled, so the grid moves on
  // with each refresh and not with each render
  const [settledAt, setSettledAt] = useState(() => Date.now());

  /* Monotonic request id, as in AuditView. A slow answer for an ABANDONED
     window must never repaint over a newer one, or the selector and the
     numbers beside it name different windows with nothing saying so.

     This is not hypothetical ordering paranoia: the ranges' reads differ a
     lot in cost (48h sums minute rows, daily sums every tier and keys the
     unrolled tail into local days), so switching between them reliably
     lands answers out of order. */
  const generation = useRef(0);

  /* The settings-backed default (DEC-A). The view paints IMMEDIATELY at the
     shipped default and corrects itself if the operator's stored preference
     differs - it never blocks on this call. `/v1/settings` reads policy.db
     while the stats routes read the separate stats.db (only a daily read
     also looks up the timezone, server-side), so gating the landing tab on
     it would invent a dependency the storage layer was deliberately built
     without. */
  useEffect(() => {
    let live = true;
    api("GET", "/v1/settings").then(({ status, data }) => {
      if (!live) return;
      if (status === 200 && data && data.settings) {
        const stored = data.settings.stats_default_range;
        if (stored && stored.value) setRange(normalizeRange(stored.value));
      }
      setSettingsSettled(true);
    });
    return () => { live = false; };
  }, []);

  const effective = normalizeRange(range || undefined);

  const load = useCallback(async () => {
    const mine = generation.current + 1;
    generation.current = mine;
    setPendingGen(mine);
    const seen = healthRef.current;
    const polled = seen ? seen.collector_last_ts || null : null;
    const [devices, line, gapRows, domains, ids, cover] = await Promise.all([
      api("GET", statsPath("/v1/stats/devices", effective)),
      api("GET", statsPath("/v1/stats/timeline", effective)),
      api("GET", gapsPath(effective)),
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
      setRowsFor(effective);
      // Present only on the day tier, and more than one means the window is
      // a union of differently-defined days rather than a single 24h one.
      setFramings(devices.data.framings || []);
    }
    if (line.status === 200) {
      setTimeline(line.data.rows || []);
      setLineTier(line.data.tier || "hour");
      setLineFor(effective);
      setLineFailed(null);
      setLinePoll(polled);
      setLastGood(`${new Date().toISOString().slice(0, 19)}Z`);
    } else {
      setLineFailed(line.status === 0 ? "unreachable" : "unavailable");
    }
    setFailedFor(line.status === 200 ? null : effective);
    if (ids.status === 200) setAliases(aliasMap(ids.data.identities));
    if (gapRows.status === 200) {
      setGaps(gapRows.data.rows || []);
      setGapsFor(effective);
    } else {
      // the gaps are UNKNOWN now: an older list for this window may miss a
      // gap since, and a bucket it does not cover must not become a zero
      setGapsFor(null);
    }
    if (domains.status === 200) setDomainsOff(domains.data.enabled === false);
    if (cover.status === 200) {
      setCoverage(cover.data);
      setCoverageFor(effective);
    }
    // the newest load for this range has settled - in the same batch as the
    // data it settled with (#100 DEC-C)
    setSettledFor(effective);
    setSettledGen(mine);
    setSettledAt(Date.now());
  }, [effective]);

  /* Not before /health first settles: the load records the poll its
     timeline is known to include, and the shell asks for /health only after
     the views' own effects have run - a landing load started at once would
     record none, and a failed refresh then had only the browser's clock to
     say "stale since". One LAN round trip, once. */
  useEffect(() => { if (healthSettled) load(); }, [load, tick, healthSettled]);

  const purge = async () => {
    if (!window.confirm(t("purge_confirm"))) return;
    const result = await api("POST", "/v1/stats/purge");
    if (result.status === 200) await load();
    else if (result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
  };

  const settled = settledFor === effective;
  // a failed read of ANOTHER range says nothing about this one's data
  const failedHere = lineFailed && failedFor === effective ? lineFailed : null;
  const ready = settingsSettled && settled && settledGen === pendingGen;
  const lastPoll = health ? health.collector_last_ts : null;
  // the poll the timeline on screen includes; with none recorded (it was
  // read before /health first answered) the newest poll, but only while
  // the reads still succeed
  const gridPoll = linePoll || (failedHere ? null : lastPoll);
  const collecting = !health || health.collector === "ok";
  // gaps read for ANOTHER window say nothing about this one: then every
  // bucket without a row is a break, not a zero
  const windowGaps = gapsFor === effective ? gaps : null;
  const grid = useMemo(() => buildGrid({
    rows: timeline, tier: lineTier,
    windowStart: windowStart(effective, new Date(settledAt)),
    lastPoll: gridPoll, gaps: windowGaps || [], gapsKnown: windowGaps !== null,
    gapsTruncated: Boolean(windowGaps && windowGaps.length >= GAPS_LIMIT),
    now: settledAt,
  }), [timeline, lineTier, effective, gridPoll, windowGaps, settledAt]);

  // the frame's state follows what the reads actually answered (DEC-E).
  // Stale outranks empty: "no traffic" from a collector that has stopped,
  // or from a read that has since failed, is not a measurement of now.
  let frame = null;
  let frameSince = "";
  if (lineFor === effective) {
    if (failedHere || !collecting) {
      frame = "stale";
      // a failed read: the poll the data on screen includes; a stopped
      // collector: its last poll. Failing either, when this view last read
      // the timeline (all UTC)
      frameSince = (failedHere ? linePoll : lastPoll || linePoll)
        || lastGood || "-";
    } else if (!timeline.length) {
      frame = "empty";
    } else {
      frame = "fresh";
    }
  } else if (settled && failedHere) {
    frame = "unavailable";
  }

  // the coverage report read for THIS window only
  const windowCoverage = coverageFor === effective ? coverage : null;
  const attributable = windowCoverage
    ? (windowCoverage.classes || []).find((c) => c.klass === "hostname")
    : null;
  const shares = windowCoverage ? shareSegments(windowCoverage, t) : [];
  const top = rowsFor === effective ? rows.slice()
    .sort((a, b) => (b.up + b.down) - (a.up + a.down) || (a.device < b.device ? -1 : 1))
    .slice(0, TOP_N)
    .map((row) => ({ key: row.device, label: labelFor(row.device, aliases),
                     up: row.up, down: row.down })) : [];

  return (
    <Stack spacing={1.5}>
      {/* readiness (#100 DEC-C): the settings read and the newest load for
          the range on screen have both settled */}
      {ready
        ? <span data-testid="stats-ready" data-range={effective} hidden />
        : null}
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

      <ChartFrame id="stats-chart-frame" state={frame} since={frameSince}
                  reason={failedHere || ""} t={t}>
        <TimeSeries grid={grid} testid="stats-sparkline" t={t} />
      </ChartFrame>

      {top.length ? (
        <Stack spacing={0.5}>
          <Typography variant="subtitle2">{t("top_devices")}</Typography>
          <TopBars testid="stats-top" rows={top} />
        </Stack>
      ) : null}

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

      {/* only once a read has settled: before an answer there is nothing to
          say, and "no traffic" would be a claim nobody measured */}
      {rows.length === 0 && (settled || problem) ? (
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

      {shares.length ? (
        <Stack spacing={0.5}>
          <Typography variant="subtitle2">{t("share_title")}</Typography>
          <ShareBar testid="stats-share" segments={shares} />
        </Stack>
      ) : null}

      {attributable ? (
        <Typography variant="body2" color="text.secondary" data-testid="coverage-note">
          {`${t("coverage_note")}: ${attributable.share.toFixed(1)}% `
           + `(${t("coverage_window")}: ${windowCoverage.window.retention_days}d)`}
          {windowCoverage.window.truncated ? ` — ${t("coverage_truncated")}` : ""}
        </Typography>
      ) : null}

      {windowGaps && windowGaps.length ? (
        <Typography variant="body2" color="warning.main" data-testid="gaps-note">
          {`${t("gaps_note")}: ${windowGaps.length}`
           + `${windowGaps.length >= GAPS_LIMIT ? "+" : ""}`}
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

function shareSegments(coverage, t) {
  const dictionary = coverage.dictionary && coverage.dictionary.classes;
  const classes = dictionary || coverage.classes || [];
  const tones = dictionary ? DICTIONARY_TONES : COVERAGE_TONES;
  const permanent = dictionary ? "unattributed" : "ip_only";
  return classes.filter((c) => c.klass in tones).map((c) => ({
    key: c.klass, label: t(`class_${c.klass}`), share: Number(c.share) || 0,
    tone: tones[c.klass], permanent: c.klass === permanent,
  }));
}
