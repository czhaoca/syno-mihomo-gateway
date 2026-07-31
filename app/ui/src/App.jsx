import { useCallback, useEffect, useRef, useState } from "react";
import Alert from "@mui/material/Alert";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import Stack from "@mui/material/Stack";
import Tab from "@mui/material/Tab";
import Tabs from "@mui/material/Tabs";
import Typography from "@mui/material/Typography";

import { api, registerTokenPrompt, setToken } from "./api.js";
import { clearAll } from "./applystate.js";
import { htmlLang, initialLang, loadDict, rememberLang, translator } from "./i18n.js";
import { TextInput } from "./controls.jsx";
import AuditView from "./views/AuditView.jsx";
import DevicesView from "./views/DevicesView.jsx";
import SettingsView from "./views/SettingsView.jsx";
import StatsView from "./views/StatsView.jsx";

/* The panel shell.

   Stats is the LANDING tab - the point of this rewrite. The question an
   operator opens the panel with is "what is my network doing"; the classic
   tree opened on the policy editor instead.

   Health reporting is carried over verbatim from the classic tree because it
   is the panel's core promise rather than decoration: the dot's title states
   the real parity, and the drift banner is driven by the API's answer alone.
   A banner that is always shown is exactly as useless as one that never is. */

const REFRESH_MS = 10000;
const NOTICE_KEEP = 4;

const TABS = [
  { id: "stats", label: "tab_stats" },
  { id: "devices", label: "tab_devices" },
  { id: "audit", label: "tab_audit" },
  { id: "settings", label: "tab_settings" },
];

export default function App() {
  const [lang, setLang] = useState(initialLang);
  const [dict, setDict] = useState({});
  const [tab, setTab] = useState("stats");
  const [health, setHealth] = useState(null);
  const [reachable, setReachable] = useState(true);
  const [notices, setNotices] = useState([]);
  const [tick, setTick] = useState(0);
  const [tokenAsk, setTokenAsk] = useState(null);
  const tokenInput = useRef(null);

  const t = translator(dict);

  useEffect(() => {
    let live = true;
    loadDict(lang).then((d) => { if (live) setDict(d); });
    document.documentElement.lang = htmlLang(lang);
    return () => { live = false; };
  }, [lang]);

  useEffect(() => {
    if (dict.app_title) document.title = dict.app_title;
  }, [dict]);

  /* Stack rather than overwrite, and never through `alert()`: a browser can
     switch dialogs off for a page, which turns alert() into a silent no-op -
     tolerable for a nag, fatal for a warning that the gateway may not match
     what the UI shows. Identical consecutive messages collapse; only the last
     few are kept, because alert() QUEUED and a single slot would silently
     drop an unread warning when a second failure followed it. */
  const notify = useCallback((message) => {
    setNotices((prev) => {
      if (prev.length && prev[prev.length - 1] === message) return prev;
      return [...prev, message].slice(-NOTICE_KEEP);
    });
  }, []);

  /* The last GOOD /health payload, kept until another one replaces it, with
     reachability tracked separately.

     Discarding it on a failed read would be an honesty regression of exactly
     the kind this panel exists to prevent: a transient failure after a
     `parity=failed` answer would take the drift banner down and let every
     badge fall back to `saved`, when no API response ever said parity
     recovered. The classic tree returned early here for the same reason. The
     dot still goes red immediately - being unreachable is real and is worth
     showing - but nothing else is retracted on silence. */
  const refreshHealth = useCallback(async () => {
    const { status, data } = await api("GET", "/health");
    if (status === 200 && data) {
      setHealth(data);
      setReachable(true);
      return;
    }
    setReachable(false);
  }, []);

  useEffect(() => { refreshHealth(); }, [refreshHealth]);

  useEffect(() => {
    const id = setInterval(() => {
      refreshHealth();
      setTick((n) => n + 1);
    }, REFRESH_MS);
    return () => clearInterval(id);
  }, [refreshHealth]);

  // The prompt is a singleton at the api.js level; this only supplies the
  // dialog. Resolving with `false` on cancel is what lets the caller take its
  // 403 path instead of waiting forever on an answer that is not coming.
  useEffect(() => {
    registerTokenPrompt(() => new Promise((resolve) => setTokenAsk(() => resolve)));
  }, []);

  const closeToken = (save) => {
    const resolve = tokenAsk;
    const value = tokenInput.current ? tokenInput.current.value : "";
    setTokenAsk(null);
    if (save) setToken(value);
    if (tokenInput.current) tokenInput.current.value = "";
    if (resolve) resolve(Boolean(save));
  };

  const parity = health ? health.parity : "unknown";
  const dotState = (!health || !reachable) ? "bad"
    : (health.db_ok && health.parity === "ok") ? "ok"
      : (health.db_ok ? "warn" : "bad");
  const dotColor = { ok: "#16a34a", warn: "#d97706", bad: "#dc2626" }[dotState];

  const reapply = async () => {
    const result = await api("POST", "/v1/apply");
    if (result.status === 200 && result.data && result.data.applied) clearAll();
    await refreshHealth();
    setTick((n) => n + 1);
  };

  const shared = { t, notify, tick, health, refreshHealth };

  return (
    <Box data-testid="app-shell" sx={{ pb: 4 }}>
      <Box
        component="header"
        sx={{
          display: "flex", alignItems: "center", justifyContent: "space-between",
          gap: 1, px: 1.5, py: 1, bgcolor: "background.paper",
          borderBottom: "1px solid", borderColor: "divider", flexWrap: "wrap",
        }}
      >
        <Typography variant="h6" component="h1" data-i18n="app_title">
          {t("app_title")}
        </Typography>
        <Stack direction="row" spacing={1.5} alignItems="center">
          <Box
            data-testid="health-dot"
            // The last known parity is still reported when the panel goes
            // quiet, but it says that it is stale rather than passing for
            // current - the honest middle between retracting it and lying.
            title={health
              ? `parity=${health.parity} collector=${health.collector}`
                + (reachable ? "" : ` (${t("unreachable_stale")})`)
              : t("unreachable")}
            sx={{ width: 12, height: 12, borderRadius: "50%", bgcolor: dotColor }}
          />
          <Box
            component="a"
            data-testid="dashboard-link"
            href={health && health.dashboard_port
              ? `//${location.hostname}:${health.dashboard_port}` : "#"}
            target="_blank"
            rel="noopener"
            sx={{ color: "primary.main", fontSize: "0.9rem" }}
          >
            {t("dashboard_link")}
          </Box>
          <Button
            data-testid="lang-toggle"
            onClick={() => {
              const next = lang === "zh" ? "en" : "zh";
              rememberLang(next);
              setLang(next);
            }}
          >
            EN/中文
          </Button>
        </Stack>
      </Box>

      {parity === "failed" ? (
        <Alert
          severity="error"
          data-testid="parity-banner"
          sx={{ borderRadius: 0 }}
          action={(
            <Button data-testid="reapply-btn" color="inherit" onClick={reapply}>
              {t("reapply")}
            </Button>
          )}
        >
          {t("parity_drift_banner")}
        </Alert>
      ) : null}

      {notices.length ? (
        <Alert
          severity="warning"
          role="alert"
          data-testid="notice"
          // Sticky: being unsuppressible is worthless if the message renders
          // above the fold and the reader has already scrolled past it.
          sx={{ position: "sticky", top: 0, zIndex: 10, borderRadius: 0 }}
          action={(
            <Button
              data-testid="notice-dismiss"
              color="inherit"
              onClick={() => setNotices([])}
            >
              {t("dismiss")}
            </Button>
          )}
        >
          <Box data-testid="notice-text">
            {notices.map((line, i) => (
              <Box key={`${line}:${i}`} className="notice-line">{line}</Box>
            ))}
          </Box>
        </Alert>
      ) : null}

      <Tabs
        value={tab}
        onChange={(_e, next) => setTab(next)}
        variant="scrollable"
        scrollButtons={false}
        sx={{ borderBottom: "1px solid", borderColor: "divider",
              bgcolor: "background.paper" }}
      >
        {TABS.map((entry) => (
          <Tab
            key={entry.id}
            value={entry.id}
            label={t(entry.label)}
            data-testid={`tab-${entry.id}`}
            sx={{ minHeight: 48, textTransform: "none" }}
          />
        ))}
      </Tabs>

      <Box component="main" sx={{ p: 1.5, mx: "auto", maxWidth: viewWidth(tab) }}>
        {tab === "stats" ? <StatsView {...shared} /> : null}
        {tab === "devices" ? <DevicesView {...shared} /> : null}
        {tab === "audit" ? <AuditView {...shared} /> : null}
        {tab === "settings" ? <SettingsView {...shared} /> : null}
      </Box>

      {tokenAsk ? (
        <Box
          data-testid="token-dialog"
          sx={{
            position: "fixed", inset: 0, display: "flex", alignItems: "center",
            justifyContent: "center", bgcolor: "rgba(0,0,0,0.4)", zIndex: 20, p: 2,
          }}
        >
          <Box sx={{ bgcolor: "background.paper", p: 2, borderRadius: 2,
                     maxWidth: 420, width: "100%" }}>
            <Typography sx={{ mb: 1 }}>{t("token_prompt")}</Typography>
            <TextInput
              data-testid="token-input"
              type="password"
              autoComplete="off"
              ref={tokenInput}
              style={{ width: "100%" }}
            />
            <Stack direction="row" spacing={1} sx={{ mt: 1.5 }}>
              <Button data-testid="token-save" variant="contained"
                      onClick={() => closeToken(true)}>
                {t("save")}
              </Button>
              <Button data-testid="token-cancel" onClick={() => closeToken(false)}>
                {t("cancel")}
              </Button>
            </Stack>
          </Box>
        </Box>
      ) : null}
    </Box>
  );
}

/* Per-view widths, replacing the single 640px cap that rendered the
   five-column audit log in ~614px on a 2560px desktop - the defect that
   started this epic. Device cards and forms still read best in a narrow
   column; the tables want every pixel the viewport has. */
function viewWidth(tab) {
  if (tab === "audit") return 1440;
  if (tab === "stats") return 1040;
  return 720;
}
