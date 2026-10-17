import { useCallback, useEffect, useState } from "react";
import Button from "@mui/material/Button";
import Stack from "@mui/material/Stack";

import { api } from "../api.js";
import { SelectInput } from "../controls.jsx";
import useGatewayReads from "../hooks/useGatewayReads.js";
import { formatHash } from "../hooks/useHashRoute.js";
import useScopedStats from "../hooks/useScopedStats.js";
import { LIMIT_MAX, PAGE, RANGES, aliasMap, labelFor, normalizeRange } from "../stats.js";
import AnalyticsView from "./insights/AnalyticsView.jsx";
import AppScope from "./insights/AppScope.jsx";
import Breadcrumbs from "./insights/Breadcrumbs.jsx";
import ClientScope from "./insights/ClientScope.jsx";
import HostScope from "./insights/HostScope.jsx";
import Overview from "./insights/Overview.jsx";

/* Gateway Insights (#101), the landing tab: one scoped view - the whole
   gateway, a client, a category, a hostname - routed in the hash, read
   with one overview fetch per tick.

   The shell owns what every scope shares: the range (the route's, else the
   operator's stored default, else the shipped one), refresh and purge, the
   breadcrumbs, the aliases, and how many values each list shows. Every
   honesty rule the Stats view kept holds here: a failed read never retracts
   what is on screen, an answer for another window or scope is never shown
   as this one's, and "no traffic" is said only by an answer.

   The settings read never blocks the first paint (#80 DEC-A): the view
   reads at the shipped default and corrects itself if the stored
   preference differs. */

const DESCRIPTORS = [
  [(scope) => Boolean(scope.host), HostScope],
  [(scope) => scope.app !== null && scope.app !== undefined, AppScope],
  [(scope) => Boolean(scope.client), ClientScope],
];

function descriptorFor(scope) {
  const hit = DESCRIPTORS.find(([test]) => test(scope));
  return hit ? hit[1] : Overview;
}

export default function InsightsView({ t, notify, tick, health, healthSettled,
                                       route, navigate }) {
  const [stored, setStored] = useState(null);
  const [settingsSettled, setSettingsSettled] = useState(false);
  const [aliases, setAliases] = useState(() => new Map());
  // how many values each list shows, for ONE view; another view starts over
  const [sizes, setSizes] = useState({ view: "", counts: {} });

  useEffect(() => {
    let live = true;
    api("GET", "/v1/settings").then(({ status, data }) => {
      if (!live) return;
      if (status === 200 && data && data.settings) {
        const value = data.settings.stats_default_range;
        if (value && value.value) setStored(normalizeRange(value.value));
      }
      setSettingsSettled(true);
    });
    return () => { live = false; };
  }, []);

  const readAliases = useCallback(async () => {
    const { status, data } = await api("GET", "/v1/identity");
    if (status === 200 && data) setAliases(aliasMap(data.identities));
  }, []);
  useEffect(() => { readAliases(); }, [readAliases]);

  const scope = route.scope;
  const range = normalizeRange(route.range || stored || undefined);
  const view = `${range}|${scope.client || ""}|${scope.app ?? "-"}|${scope.host || ""}`;
  const counts = sizes.view === view ? sizes.counts : {};
  const countOf = (dim) => counts[dim] || PAGE;
  const limit = Math.max(PAGE, ...Object.values(counts));
  const descriptor = descriptorFor(scope);

  const stats = useScopedStats({ range, scope, limit, tick, health, healthSettled });
  const busy = !stats.ready;
  // the gateway widgets' own reads (#103 DEC-D): only in a gateway view
  const widgets = useGatewayReads({ enabled: Boolean(descriptor.gateway), range,
                                    tick, healthSettled });

  const more = (dim) => setSizes({
    view, counts: { ...counts, [dim]: Math.min(countOf(dim) + PAGE, LIMIT_MAX) },
  });
  const hrefFor = (next) => formatHash({ tab: "stats", scope: { client: null,
    app: null, host: null, ...next }, range });
  const refresh = () => {
    stats.refresh();
    widgets.refresh();
    readAliases();
  };
  const purge = async () => {
    if (!window.confirm(t("purge_confirm"))) return;
    const result = await api("POST", "/v1/stats/purge");
    // the bare purge also deletes the node delay and the quota (#102): the
    // widgets re-read with the overview, never drawing deleted figures
    if (result.status === 200) {
      await Promise.all([stats.refresh(), widgets.refresh({ forget: true })]);
    }
    else if (result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
  };

  const crumbs = [{ key: "overview", label: t("scope_overview"),
                    href: hrefFor({}) }];
  if (scope.client) {
    crumbs.push({ key: "client",
                  label: `${t("scope_client")} ${labelFor(scope.client, aliases)}`,
                  href: hrefFor({ client: scope.client }) });
  }
  if (scope.app !== null && scope.app !== undefined) {
    crumbs.push({ key: "app", href: "",
                  label: `${t("scope_app")} ${categoryName(scope.app, t)}` });
  } else if (scope.host) {
    crumbs.push({ key: "host", href: "", label: `${t("scope_host")} ${scope.host}` });
  }

  return (
    <Stack spacing={1.5}>
      {/* readiness (#100 DEC-C): the settings read and the newest read for
          the view on screen have both settled */}
      {settingsSettled && stats.ready
        ? <span data-testid="stats-ready" data-range={range}
                data-scope={descriptor.id} hidden />
        : null}
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap"
             useFlexGap>
        <SelectInput
          data-testid="stats-range"
          aria-label={t("range_label")}
          value={range}
          onChange={(e) => navigate({ tab: "stats", scope, range: e.target.value })}
        >
          {RANGES.map((r) => (
            <option key={r} value={r}>{t(`range_${r}`)}</option>
          ))}
        </SelectInput>
        <Button data-testid="stats-refresh" onClick={refresh}>{t("refresh")}</Button>
        <Button data-testid="stats-purge" color="error" onClick={purge}>
          {t("purge_stats")}
        </Button>
      </Stack>

      <Breadcrumbs crumbs={crumbs} t={t} />

      <AnalyticsView t={t} descriptor={descriptor} scope={scope} range={range}
                     view={stats} health={health} aliases={aliases}
                     counts={Object.fromEntries(
                       descriptor.order.map((dim) => [dim, countOf(dim)]))}
                     onMore={more} busy={busy} hrefFor={hrefFor}
                     widgets={descriptor.gateway ? widgets : null} />
    </Stack>
  );
}

function categoryName(value, t) {
  if (value === "") return t("class_no_dictionary");
  if (value === "unknown") return t("class_unattributed");
  return value;
}
