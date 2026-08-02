import { useCallback, useEffect, useState } from "react";
import Box from "@mui/material/Box";
import Button from "@mui/material/Button";
import Card from "@mui/material/Card";
import Chip from "@mui/material/Chip";
import Stack from "@mui/material/Stack";
import Typography from "@mui/material/Typography";

import { api } from "../api.js";
import {
  badgeFor, forget, markApplying, markDrift, noteApplyResult,
} from "../applystate.js";
import { SelectInput, Sparkline, TextInput } from "../controls.jsx";
import { displayName, hostIp, inBand, isHost } from "../devices.js";

// `label` carries the i18n key as a literal on purpose: a key assembled at
// the call site (`t(`mode_${mode.replace("-", "_")}`)`) is invisible to the
// bilingual gate, and an untranslated label would ship unnoticed.
const MODES = [
  { mode: "default", label: "mode_default" },
  { mode: "full-direct", label: "mode_full_direct" },
  { mode: "full-tunnel", label: "mode_full_tunnel" },
];
const BADGE_COLOR = {
  saved: "default", applying: "primary", confirmed: "success", drift: "error",
};

// Whether the address the operator TYPED will canonicalize to a single host.
// A bare address becomes a /32; anything else is a range, and a range can
// never carry an alias (identity keys on a /32).
function typedHost(address) {
  return !address.includes("/") || address.endsWith("/32");
}

export default function DevicesView({ t, notify, tick, health, refreshHealth }) {
  const [devices, setDevices] = useState([]);
  const [band, setBand] = useState([]);
  const [loaded, setLoaded] = useState(false);
  const [history, setHistory] = useState({});
  const [form, setForm] = useState({ address: "", name: "", mode: "full-tunnel" });

  const parity = health ? health.parity : "unknown";

  const refresh = useCallback(async () => {
    const { status, data } = await api("GET", "/v1/devices");
    // Only discard the list once a good answer is in hand: a failed refresh
    // must not wipe a correctly-rendered view and leave the operator staring
    // at nothing.
    if (status !== 200) return;
    setDevices(data.devices || []);
    setBand(data.band || []);
    setLoaded(true);
  }, []);

  useEffect(() => { refresh(); }, [refresh, tick]);

  const complain = (result) => {
    if (result.status !== 403) {
      notify((result.data && result.data.detail) || t("error_generic"));
    }
  };

  const setMode = async (dev, mode) => {
    if (mode === dev.mode) return;
    if (dev.band_member && !window.confirm(t("band_confirm"))) return;
    markApplying(dev.cidr);
    await refresh();
    const result = mode === "default"
      ? await api("DELETE", `/v1/devices/${dev.id}`)
      : await api("PATCH", `/v1/devices/${dev.id}`, { mode });
    if (result.status === 200) {
      noteApplyResult(dev.cidr, result.data);
      if (mode === "default" && result.data && result.data.applied === false) {
        // The row is gone, so no per-row badge can carry this drift - say it
        // out loud rather than let the removal read as a success.
        notify(t("delete_drift_warn"));
      }
    } else if (result.status !== 403) {
      markDrift(dev.cidr);
      complain(result);
    } else {
      forget(dev.cidr);
    }
    await refreshHealth();
    await refresh();
  };

  /* One rename control, two write targets (DEC-C).

     A /32 writes the ALIAS, which is the identity-layer name: it survives the
     policy being removed and an operator's own edit outranks every importer.
     A range has no host to key an alias on, so its `devices.name` is the only
     name it can carry - unchanged from the classic tree. Never both. */
  const rename = async (dev) => {
    const current = displayName(dev, "");
    const next = window.prompt(t("rename_prompt"), current);
    if (next === null || next === current) return;
    const result = isHost(dev.cidr)
      ? await api("PUT", `/v1/identity/${hostIp(dev.cidr)}`, { alias: next })
      : await api("PATCH", `/v1/devices/${dev.id}`, { name: next });
    if (result.status !== 200 && result.status !== 403) complain(result);
    await refresh();
  };

  const toggleHistory = async (dev) => {
    if (history[dev.cidr]) {
      setHistory((prev) => ({ ...prev, [dev.cidr]: null }));
      return;
    }
    const device = dev.cidr.split("/")[0];
    const { status, data } = await api(
      "GET", `/v1/stats/timeline?tier=minute&device=${encodeURIComponent(device)}`);
    // An empty chart and a chart that could not be read are pixel-identical,
    // and they mean opposite things - one says this device sent nothing, the
    // other says nobody knows. Say so instead of drawing the flat line.
    if (status !== 200) {
      notify(t("history_failed"));
      return;
    }
    setHistory((prev) => ({ ...prev, [dev.cidr]: data.rows || [] }));
  };

  const addDevice = async (evt) => {
    evt.preventDefault();
    const address = form.address.trim();
    const name = form.name.trim();
    /* The band gate covers ADDS, not just flips on listed rows, and the
       decision must rest on a FRESH server answer - a cached band goes stale
       the moment the router-side knob changes. An unreadable band fails
       CLOSED: ask rather than silently skip the gate. */
    const check = await api("GET", "/v1/devices");
    let current = band;
    if (check.status === 200) {
      current = check.data.band || [];
      setBand(current);
    } else if (!window.confirm(t("band_confirm_unknown"))) {
      return;
    }
    if (inBand(address, current) && !window.confirm(t("band_confirm"))) return;

    /* A host's name goes to the identity layer, so the ADD path branches
       exactly as rename does. If it did not, every device named at creation
       would carry a policy label that its first rename displaces - and the
       divergence the interface reports as an exception would become the
       normal state of every row. */
    const host = typedHost(address);
    const result = await api("POST", "/v1/devices",
                             host ? { address, mode: form.mode }
                                  : { address, name, mode: form.mode });
    if (result.status === 201) {
      noteApplyResult(result.data.device.cidr, result.data);
      if (host && name) {
        // Two writes, no transaction between them. A failure here leaves the
        // device added but unnamed, which is why it is reported rather than
        // swallowed: the rename control is the retry.
        //
        // EVERY non-200 is reported, 403 included - the exemption the other
        // calls make for it does not apply to a SECOND write. There a 403
        // means the operator dismissed the token prompt and nothing happened;
        // here the device already exists, so silence would leave it named in
        // the form and unnamed in the panel.
        const alias = await api(
          "PUT", `/v1/identity/${hostIp(result.data.device.cidr)}`,
          { alias: name });
        if (alias.status !== 200) notify(t("alias_write_failed"));
      }
      setForm((prev) => ({ address: "", name: "", mode: prev.mode }));
    } else if (result.status !== 403) {
      complain(result);
    }
    await refreshHealth();
    await refresh();
  };

  return (
    <Stack spacing={1.5}>
      <Box component="form" data-testid="add-form" onSubmit={addDevice}
           sx={{ display: "grid", gap: 1,
                 gridTemplateColumns: { xs: "1fr", sm: "1fr 1fr" } }}>
        <TextInput
          data-testid="add-address"
          value={form.address}
          required
          placeholder={t("add_address_ph")}
          onChange={(e) => setForm((prev) => ({ ...prev, address: e.target.value }))}
          style={{ gridColumn: "1 / -1" }}
        />
        <TextInput
          data-testid="add-name"
          value={form.name}
          placeholder={t("add_name_ph")}
          onChange={(e) => setForm((prev) => ({ ...prev, name: e.target.value }))}
        />
        <SelectInput
          data-testid="add-mode"
          value={form.mode}
          onChange={(e) => setForm((prev) => ({ ...prev, mode: e.target.value }))}
        >
          <option value="full-tunnel">{t("mode_full_tunnel")}</option>
          <option value="full-direct">{t("mode_full_direct")}</option>
        </SelectInput>
        <Button data-testid="add-submit" type="submit" variant="contained"
                sx={{ gridColumn: "1 / -1" }}>
          {t("add_device")}
        </Button>
      </Box>

      <Stack spacing={1} data-testid="device-list">
        {devices.map((dev) => {
          const state = badgeFor(dev.cidr, parity);
          return (
            <Card key={dev.cidr} data-testid={`device-${dev.cidr}`}
                  variant="outlined" sx={{ p: 1.2 }}>
              <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap"
                     useFlexGap>
                <Typography sx={{ fontWeight: 600 }} data-testid="device-name">
                  {displayName(dev, t("unnamed"))}
                </Typography>
                <Typography variant="body2" color="text.secondary"
                            sx={{ fontFamily: "ui-monospace, monospace" }}>
                  {dev.cidr}
                </Typography>
                {dev.band_member ? (
                  <Chip size="small" color="warning" variant="outlined"
                        label={t("band_badge")} />
                ) : null}
                <Chip size="small" color={BADGE_COLOR[state]} variant="outlined"
                      label={t(`state_${state}`)} />
              </Stack>

              <Stack direction="row" spacing={0.6} sx={{ mt: 0.8 }} flexWrap="wrap"
                     useFlexGap>
                {MODES.map((entry) => (
                  <Button
                    key={entry.mode}
                    data-testid={`mode-${entry.mode}`}
                    variant={dev.mode === entry.mode ? "contained" : "outlined"}
                    onClick={() => setMode(dev, entry.mode)}
                  >
                    {t(entry.label)}
                  </Button>
                ))}
                <Button data-testid="device-rename" onClick={() => rename(dev)}>
                  {t("rename")}
                </Button>
                <Button data-testid="device-history"
                        onClick={() => toggleHistory(dev)}>
                  {t("history")}
                </Button>
              </Stack>

              {history[dev.cidr] ? (
                <Box sx={{ mt: 1 }}>
                  <Sparkline rows={history[dev.cidr]} height={40}
                             testid={`device-sparkline-${dev.cidr}`} />
                </Box>
              ) : null}
            </Card>
          );
        })}
      </Stack>

      {loaded && devices.length === 0 ? (
        <Typography variant="body2" color="text.secondary"
                    data-testid="devices-empty">
          {t("devices_empty")}
        </Typography>
      ) : null}
    </Stack>
  );
}
