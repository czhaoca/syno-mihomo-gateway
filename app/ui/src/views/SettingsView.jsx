import { useCallback, useEffect, useRef, useState } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import Card from "@mui/material/Card";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";

import { api } from "../api.js";
import { SelectInput, TextInput } from "../controls.jsx";
import { RANGES } from "../stats.js";

/* The settings page (#80).

   `/v1/settings` reports three things per key - the effective value, the
   default it would fall back to, and whether an override is stored - and all
   three are rendered. Showing only the value would present an INHERITED
   setting as a stored choice, which is the same class of lie as a badge
   claiming an apply reached mihomo when it did not. `overridden` is what
   tells the operator whether clearing the field will change anything.

   A blank value REVERTS a key to its code default rather than storing an
   empty string, so the clear affordance is just an empty field plus Save. */

const KEYS = [
  { key: "timezone", label: "setting_timezone", kind: "text" },
  { key: "day_boundary", label: "setting_day_boundary", kind: "text" },
  { key: "stats_default_range", label: "setting_default_range", kind: "range" },
];

export default function SettingsView({ t, notify }) {
  const [settings, setSettings] = useState(null);
  const [draft, setDraft] = useState({});
  const [changed, setChanged] = useState(null);
  const [identities, setIdentities] = useState([]);
  const [alias, setAlias] = useState({ ip: "", name: "" });

  /* The keys the operator has edited but not saved. The seed below must
     never overwrite one: `/v1/settings` is fetched when the tab opens, and a
     response landing a moment after they start typing would wipe the
     keystroke with no error and no explanation - the same silent-discard
     class of bug as a badge that lies. Only a SAVE re-seeds, because at that
     point the server's answer is the truth about what was stored.

     Tracked PER KEY rather than as one flag for the form: a single flag would
     let one keystroke suppress the seed for every OTHER field too, leaving
     them rendering blank while the panel holds real values for them. */
  const dirty = useRef(new Set());

  const loadSettings = useCallback(async ({ reseed = false } = {}) => {
    const { status, data } = await api("GET", "/v1/settings");
    if (status !== 200 || !data) return;
    setSettings(data.settings);
    // Seed each key from its EFFECTIVE value, so saving an untouched form is
    // a no-op rather than a silent revert of every key the operator did not
    // look at - but never over an unsaved edit to that same key.
    setDraft((prev) => Object.fromEntries(
      Object.entries(data.settings).map(([k, v]) => [
        k, (!reseed && dirty.current.has(k)) ? prev[k] : v.value])));
    if (reseed) dirty.current = new Set();
  }, []);

  const edit = useCallback((key, value) => {
    dirty.current.add(key);
    setDraft((prev) => ({ ...prev, [key]: value }));
  }, []);

  const loadIdentities = useCallback(async () => {
    const { status, data } = await api("GET", "/v1/identity");
    if (status === 200 && data) setIdentities(data.identities || []);
  }, []);

  useEffect(() => { loadSettings(); loadIdentities(); },
            [loadSettings, loadIdentities]);

  const save = async () => {
    setChanged(null);
    const result = await api("PUT", "/v1/settings", { values: draft });
    if (result.status === 200) {
      setSettings(result.data.settings);
      // `changed` lists the keys whose stored OVERRIDE moved - broader than
      // "the resolved value moved", because pinning today's default changes
      // nothing visible now and changes what a later redeploy does.
      setChanged(result.data.changed || []);
      await loadSettings({ reseed: true });
    } else if (result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
  };

  const saveAlias = async (evt) => {
    evt.preventDefault();
    const ip = alias.ip.trim();
    if (!ip) return;
    const result = await api("PUT", `/v1/identity/${encodeURIComponent(ip)}`,
                             { alias: alias.name.trim() });
    if (result.status === 200) setAlias({ ip: "", name: "" });
    else if (result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
    await loadIdentities();
  };

  const removeAlias = async (ip) => {
    const result = await api("DELETE", `/v1/identity/${encodeURIComponent(ip)}`);
    if (result.status !== 200 && result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
    await loadIdentities();
  };

  return (
    <Stack spacing={2}>
      <Card variant="outlined" sx={{ p: 1.5 }} data-testid="settings-card">
        <Typography variant="subtitle1" sx={{ mb: 1 }}>
          {t("settings_title")}
        </Typography>
        <Stack spacing={1.5}>
          {KEYS.map(({ key, label, kind }) => {
            const row = settings ? settings[key] : null;
            return (
              <Box key={key}>
                <Typography variant="body2" component="label" htmlFor={`set-${key}`}>
                  {t(label)}
                </Typography>
                {kind === "range" ? (
                  <SelectInput
                    id={`set-${key}`}
                    data-testid={`settings-${key}`}
                    value={draft[key] ?? ""}
                    onChange={(e) => edit(key, e.target.value)}
                    style={{ display: "block", width: "100%" }}
                  >
                    {RANGES.map((r) => (
                      <option key={r} value={r}>{t(`range_${r}`)}</option>
                    ))}
                  </SelectInput>
                ) : (
                  <TextInput
                    id={`set-${key}`}
                    data-testid={`settings-${key}`}
                    value={draft[key] ?? ""}
                    onChange={(e) => edit(key, e.target.value)}
                    style={{ display: "block", width: "100%" }}
                  />
                )}
                {row ? (
                  <Typography variant="caption" color="text.secondary"
                              data-testid={`settings-${key}-origin`}>
                    {row.overridden
                      ? t("setting_overridden")
                      : `${t("setting_inherited")}: ${row.default}`}
                  </Typography>
                ) : null}
              </Box>
            );
          })}
          <Box>
            {/* Every field renders empty until the seed lands, and a blank
                value REVERTS its key. Saving before the form knows what it is
                editing would therefore wipe every override at once - so the
                button waits for the answer even though the fields do not. */}
            <Button data-testid="settings-save" variant="contained"
                    disabled={!settings} onClick={save}>
              {t("save")}
            </Button>
          </Box>
          {changed ? (
            <Typography variant="body2" data-testid="settings-changed">
              {changed.length
                ? `${t("settings_changed")}: ${changed.join(", ")}`
                : t("settings_unchanged")}
            </Typography>
          ) : null}
        </Stack>
      </Card>

      <Card variant="outlined" sx={{ p: 1.5 }} data-testid="alias-card">
        <Typography variant="subtitle1" sx={{ mb: 1 }}>
          {t("aliases_title")}
        </Typography>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
          {t("aliases_help")}
        </Typography>
        <Box component="form" onSubmit={saveAlias} data-testid="alias-form"
             sx={{ display: "grid", gap: 1,
                   gridTemplateColumns: { xs: "1fr", sm: "1fr 1fr auto" } }}>
          <TextInput
            data-testid="alias-ip"
            value={alias.ip}
            placeholder={t("alias_ip_ph")}
            onChange={(e) => setAlias((prev) => ({ ...prev, ip: e.target.value }))}
          />
          <TextInput
            data-testid="alias-name"
            value={alias.name}
            placeholder={t("alias_name_ph")}
            onChange={(e) => setAlias((prev) => ({ ...prev, name: e.target.value }))}
          />
          <Button data-testid="alias-save" type="submit" variant="contained">
            {t("save")}
          </Button>
        </Box>

        <Stack spacing={0.5} sx={{ mt: 1.5 }} data-testid="alias-list">
          {identities.map((row) => (
            <Stack key={row.ip} direction="row" spacing={1} alignItems="center"
                   flexWrap="wrap" useFlexGap
                   data-testid={`alias-row-${row.ip}`}>
              <Typography variant="body2"
                          sx={{ fontFamily: "ui-monospace, monospace" }}>
                {row.ip}
              </Typography>
              <Typography variant="body2" sx={{ fontWeight: 600 }}>
                {row.alias}
              </Typography>
              {/* Provenance, not decoration: an operator's own edit outranks
                  every importer, so a row's source is what explains why a
                  scheduled sync did or did not overwrite it. */}
              <Typography variant="caption" color="text.secondary">
                {row.source}
              </Typography>
              <Button data-testid="alias-remove" size="small"
                      onClick={() => removeAlias(row.ip)}
                      sx={{ minHeight: 32, py: 0 }}>
                {t("remove")}
              </Button>
            </Stack>
          ))}
        </Stack>
        {identities.length === 0 ? (
          <Typography variant="body2" color="text.secondary"
                      data-testid="alias-empty" sx={{ mt: 1 }}>
            {t("aliases_empty")}
          </Typography>
        ) : null}
      </Card>
    </Stack>
  );
}
