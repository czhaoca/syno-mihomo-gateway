import { useMemo } from "react";
import Box from "@mui/material/Box";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";

import ChartFrame from "../../charts/ChartFrame.jsx";
import ShareBar from "../../charts/ShareBar.jsx";
import TimeSeries from "../../charts/TimeSeries.jsx";
import { buildGrid, keyStart } from "../../charts/grid.js";
import {
  BEYOND_CLASS, CLASS_RETENTION_DAYS, fmtBytes, labelFor, windowStart,
} from "../../stats.js";
import LiveTile from "./LiveTile.jsx";
import NodeDelay from "./NodeDelay.jsx";
import Quota from "./Quota.jsx";
import TopList from "./TopList.jsx";

/* One scope's analytics (#101 DEC-I): a KPI row, the scoped timeline in its
   frame, the next level's top lists, and the notes that say how far each
   number can be trusted. DESCRIPTOR (Overview, ClientScope, AppScope,
   HostScope) says which lists come first, where a row drills and which
   notes the scope carries; VIEW is useScopedStats' answer.

   Every section the overview read could not answer for this scope is
   `null` with a reason - those are listed, never drawn as an empty table
   or a zero, because "this cannot be cut that way" and "nothing happened"
   are opposite statements. */

const LISTS = {
  device: { label: "list_device" },
  category: { label: "list_category" },
  exit: { label: "list_exit" },
  country: { label: "list_country" },
  host: { label: "list_host" },
};
const SECTIONS = {
  totals: { label: "kpi_total" },
  timeline: { label: "chart_title" },
  coverage: { label: "coverage_note" },
};
// the server's reasons are English; the known ones are said in the
// reader's language, anything else exactly as the server put it
const REASONS = [
  { match: "scoped to one device", label: "unavail_scoped_device" },
  { match: "scoped to one", label: "unavail_scoped_self" },
  { match: "stored independently", label: "unavail_independent" },
  { match: "hostname class is off", label: "unavail_domains_off" },
  { match: "measured for the whole gateway", label: "unavail_coverage" },
];
const DOMAINS_OFF = "hostname class is off";

// the dictionary's partition (#97), "unattributed" permanent; the
// hostname/ip_only one for a panel that does not report it
const DICTIONARY_TONES = { app: "up", coarse: "down",
                           unattributed: "unattributed", no_dictionary: "seam" };
const COVERAGE_TONES = { hostname: "up", ip_only: "unattributed" };

export default function AnalyticsView({ t, descriptor, scope, range, view,
                                        health, aliases, counts, onMore, busy,
                                        hrefFor, widgets = null }) {
  const { data, failed, stalled, linePoll, lastGood, settledAt } = view;
  const lastPoll = health ? health.collector_last_ts : null;
  const collecting = !health || health.collector === "ok";
  const timeline = data ? data.timeline : null;

  const cap = retentionDays(data);
  const shade = descriptor.shade;
  const shadeUntil = data && shade && BEYOND_CLASS.includes(range)
    ? classFloor(data, cap, linePoll, settledAt) : null;
  // the poll the answer on screen includes; with none recorded, the newest
  // poll - but only while the reads still succeed
  const gridPoll = linePoll || (failed ? null : lastPoll);
  const grid = useMemo(() => buildGrid({
    rows: timeline ? timeline.rows : [], tier: timeline ? timeline.tier : "hour",
    windowStart: windowStart(range, new Date(settledAt)), lastPoll: gridPoll,
    gaps: data && Array.isArray(data.gaps) ? data.gaps : [],
    gapsKnown: Boolean(data && Array.isArray(data.gaps)),
    gapsTruncated: Boolean(data && data.gaps_truncated),
    now: settledAt, shadeUntil, shadeOverBefore: descriptor.shadeOverBefore,
  }), [timeline, range, settledAt, gridPoll, data, shadeUntil, descriptor]);

  // the frame follows what the read answered (#100 DEC-E); stale outranks
  // empty - "no traffic" from a stopped collector or a failed read is not a
  // measurement of now
  let frame = null;
  let since = "";
  if (data && timeline) {
    if (failed || stalled || !collecting) {
      frame = "stale";
      since = (failed || stalled ? linePoll : lastPoll || linePoll) || lastGood
        || "-";
    } else {
      frame = timeline.rows.length ? "fresh" : "empty";
    }
  } else if (!data && failed) {
    frame = "unavailable";
  }

  const unavailable = data ? Object.entries(data.unavailable || {}) : [];
  const domainsOff = Boolean(data && (
    (data.top && data.top.host && data.top.host.enabled === false)
    || unavailable.some(([, reason]) => String(reason).includes(DOMAINS_OFF))));
  const totals = data ? data.totals : null;
  const zero = totals && totals.up + totals.down === 0;
  const coverage = descriptor.gateway && data ? data.coverage : null;
  const attributable = coverage
    ? (coverage.classes || []).find((c) => c.klass === "hostname") : null;
  const shares = coverage ? shareSegments(coverage, t) : [];
  const gaps = data && Array.isArray(data.gaps) ? data.gaps : [];
  const framings = data ? data.framings || [] : [];
  const scopeWindow = totals ? totals.window : null;

  const labelOf = (dim) => (row) => {
    if (dim === "device") return labelFor(row.value, aliases);
    if (dim === "category") return categoryLabel(row, t);
    return row.value === "" ? t("value_none") : row.value;
  };
  const hrefOf = (dim) => (descriptor.drill[dim]
    ? (value) => hrefFor(descriptor.drill[dim](scope, value)) : null);

  return (
    <Stack spacing={1.5}>
      {totals ? (
        <Box data-testid="stats-kpi" data-up={totals.up} data-down={totals.down}
             sx={{ display: "flex", flexWrap: "wrap", gap: 2 }}>
          <Kpi testid="stats-kpi-total" label={t("kpi_total")}
               value={fmtBytes(totals.up + totals.down)} />
          <Kpi testid="stats-kpi-up" label={t("col_up")} value={fmtBytes(totals.up)} />
          <Kpi testid="stats-kpi-down" label={t("col_down")}
               value={fmtBytes(totals.down)} />
        </Box>
      ) : null}

      {/* the gateway view's live tile (#103): off until this browser opts in */}
      {widgets ? <LiveTile t={t} /> : null}

      {data && !timeline ? null : (
        <ChartFrame id="stats-chart-frame" state={frame} since={since}
                    reason={failed || ""} t={t}
                    emptyText={descriptor.id === "app" ? t("chart_empty_category") : ""}>
          <TimeSeries grid={grid} testid="stats-sparkline" t={t}
                      shadeLabel={shade ? `${t(shade.label)} (${cap}d)` : ""} />
        </ChartFrame>
      )}

      {(!data && failed) || zero ? (
        <Typography variant="body2"
                    color={failed ? "warning.main" : "text.secondary"}
                    data-testid="stats-empty">
          {failed === "unreachable" ? t("stats_unreachable")
            : failed ? t("stats_unavailable") : t("stats_empty")}
        </Typography>
      ) : null}

      {data && data.top ? (
        <Box sx={{ display: "grid", gap: 2, minWidth: 0,
                   gridTemplateColumns: { xs: "minmax(0, 1fr)",
                                          md: "repeat(2, minmax(0, 1fr))" } }}>
          {descriptor.order.map((dim) => {
            const body = data.top[dim];
            const list = LISTS[dim];
            if (!body || (dim === "host" && body.enabled === false)) return null;
            return (
              <TopList key={dim} t={t} dim={dim} title={t(list.label)} body={body}
                       count={counts[dim]} labelOf={labelOf(dim)}
                       hrefOf={hrefOf(dim)} onMore={onMore} busy={busy} />
            );
          })}
        </Box>
      ) : null}

      {shares.length ? (
        <Stack spacing={0.5}>
          <Typography variant="subtitle2">{t("share_title")}</Typography>
          <ShareBar testid="stats-share" segments={shares} />
        </Stack>
      ) : null}

      {widgets ? (
        <Box sx={{ display: "grid", gap: 2, minWidth: 0,
                   gridTemplateColumns: { xs: "minmax(0, 1fr)",
                                          md: "repeat(2, minmax(0, 1fr))" } }}>
          <NodeDelay t={t} read={widgets.delay} range={range} collecting={collecting} />
          <Quota t={t} read={widgets.quota} collecting={collecting} />
        </Box>
      ) : null}

      {attributable ? (
        <Typography variant="body2" color="text.secondary" data-testid="coverage-note">
          {`${t("coverage_note")}: ${attributable.share.toFixed(1)}% `
           + `(${t("coverage_window")}: ${coverage.window.retention_days}d)`}
          {coverage.window.truncated ? ` — ${t("coverage_truncated")}` : ""}
        </Typography>
      ) : null}

      {scopeWindow && scopeWindow.truncated && scopeWindow.oldest_bucket ? (
        <Typography variant="body2" color="warning.main" data-testid="stats-scope-window">
          {`${t("scope_starts")} ${scopeWindow.oldest_bucket}`}
        </Typography>
      ) : null}

      {gaps.length ? (
        <Typography variant="body2" color="warning.main" data-testid="gaps-note">
          {`${t("gaps_note")}: ${gaps.length}${data.gaps_truncated ? "+" : ""}`}
        </Typography>
      ) : null}

      {framings.length > 1 ? (
        <Typography variant="body2" color="warning.main" data-testid="framings-note">
          {`${t("framings_note")}: ${framings
            .map((f) => `${f.bucket_tz} ${f.day_boundary}`).join(", ")}`}
        </Typography>
      ) : null}

      {domainsOff ? (
        <Typography variant="body2" color="text.secondary" data-testid="domains-note">
          {`${t("domains_off")} ${t("domains_optin")}`}
        </Typography>
      ) : null}

      {unavailable.length ? (
        <Box data-testid="stats-unavailable">
          <Typography variant="body2" color="text.secondary">
            {t("unavail_title")}
          </Typography>
          <Box component="ul" sx={{ m: 0, pl: 2.5 }}>
            {unavailable.map(([key, reason]) => (
              <Typography key={key} component="li" variant="body2"
                          color="text.secondary"
                          data-testid={`stats-unavailable-${key.replace(".", "-")}`}>
                {`${sectionLabel(key, t)}: ${reasonText(reason, t)}`}
              </Typography>
            ))}
          </Box>
        </Box>
      ) : null}

      {descriptor.gateway && data && data.invisible_traffic_hint
       && data.invisible_traffic_hint.code === "gateway_only" ? (
        <Typography variant="body2" color="text.secondary" data-testid="invisible-note">
          {t("hint_gateway_only")}
        </Typography>
      ) : null}
    </Stack>
  );
}

function Kpi({ testid, label, value }) {
  return (
    <Box data-testid={testid} sx={{ minWidth: 0 }}>
      <Typography variant="caption" color="text.secondary">{label}</Typography>
      <Typography variant="h6" sx={{ lineHeight: 1.2 }}>{value}</Typography>
    </Box>
  );
}

/* How many days the hostname class keeps, from the answer itself where it
   says so: the coverage report (gateway-wide), the host list's window (the
   overview and a client), the scope's own window (a host) - else the
   class's constant. */
function retentionDays(data) {
  const pick = [
    data && data.coverage && data.coverage.window,
    data && data.top && data.top.host && data.top.host.window,
    data && data.totals && data.totals.window,
  ].find((w) => w && Number.isFinite(w.retention_days));
  return pick ? pick.retention_days : CLASS_RETENTION_DAYS;
}

/* The instant the hostname class's data starts: the server's own floor (an
   hour key) where an answer carries one - its clock defines the window -
   else the last poll (the server's clock again) minus the cap. */
function classFloor(data, cap, linePoll, settledAt) {
  const floors = [
    data.top && data.top.host && data.top.host.window && data.top.host.window.since,
    data.totals && data.totals.window && data.totals.window.since,
  ].filter((key) => typeof key === "string" && key.length === 13);
  if (floors.length) return keyStart(floors[0], "hour");
  const polled = linePoll ? Date.parse(linePoll) : NaN;
  return (Number.isFinite(polled) ? polled : settledAt) - cap * 86_400_000;
}

function categoryLabel(row, t) {
  if (row.value === "" || row.class === "no_dictionary") return t("class_no_dictionary");
  if (row.value === "unknown" || row.class === "unattributed") {
    return t("class_unattributed");
  }
  return row.value;
}

function sectionLabel(key, t) {
  const [head, dim] = key.split(".");
  const section = head === "top" ? LISTS[dim] : SECTIONS[head];
  return section ? t(section.label) : key;
}

function reasonText(reason, t) {
  const known = REASONS.find((r) => String(reason).includes(r.match));
  return known ? t(known.label) : String(reason);
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
