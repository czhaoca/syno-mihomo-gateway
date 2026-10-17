import { createTheme } from "@mui/material/styles";

/* The width at which the audit log stops being a stack of cards and becomes
   a table. 760px rather than one of MUI's defaults because that is the
   threshold the classic stylesheet already tuned against the real five-column
   log; moving it would change behaviour on mid-size tablets for no stated
   reason. */
export const FOLD_PX = 760;

/* Both colour schemes (#100 DEC-B). Every colour the panel paints comes from
   here - the chart kit under src/charts may not name one at all (a test
   enforces it) - so a scheme is one table, and a dark panel can never carry
   a light-only colour left behind in a component.

   `chart` holds the kit's own tokens:
     up / down      the two directions of traffic
     gap            the hatch of a collection gap (a hole, never a zero)
     seam           the marker where a day's boundary changed
     unattributed   the permanent "no answer" segment
     before         the span before the data starts (nothing is claimed)
     stale          the span after the last good poll
     shade          the span older than the hostname class keeps (#101) -
                    bytes there are still real; the detail is not
                    (both regions are faint fills OUTLINED in `axis`: the
                    outline is what meets the 3:1 non-text contrast floor,
                    which test_ui.py holds every drawn token to)
     grid / axis    rules and labels
     surface / border  the chart's own background and outline */
const SCHEMES = {
  light: {
    primary: "#2563eb", success: "#16a34a", warning: "#d97706",
    error: "#dc2626",
    background: { default: "#f6f8fa", paper: "#ffffff" },
    text: { primary: "#1b2733", secondary: "#52606d" },
    divider: "#d7dde3",
    chart: {
      up: "#2563eb", down: "#0d9488", gap: "#d97706", seam: "#7c3aed",
      unattributed: "#64748b", before: "#eef2f6", stale: "#e2e8f0",
      shade: "#f3eefb",
      grid: "#e5e9ef", axis: "#52606d", surface: "#ffffff",
      border: "#d7dde3", overlay: "rgba(15, 23, 42, 0.45)",
    },
  },
  dark: {
    primary: "#60a5fa", success: "#4ade80", warning: "#fbbf24",
    error: "#f87171",
    background: { default: "#0f1720", paper: "#16202b" },
    text: { primary: "#e6edf3", secondary: "#9aa7b4" },
    divider: "#2b3846",
    chart: {
      up: "#60a5fa", down: "#2dd4bf", gap: "#fbbf24", seam: "#c4b5fd",
      unattributed: "#64748b", before: "#1b2633", stale: "#243142",
      shade: "#211c30",
      grid: "#223040", axis: "#9aa7b4", surface: "#16202b",
      border: "#2b3846", overlay: "rgba(0, 0, 0, 0.6)",
    },
  },
};

export const MODES = Object.keys(SCHEMES);

export function makeTheme(mode) {
  const s = SCHEMES[mode] || SCHEMES.light;
  return createTheme({
    palette: {
      mode: mode === "dark" ? "dark" : "light",
      primary: { main: s.primary },
      success: { main: s.success },
      warning: { main: s.warning },
      error: { main: s.error },
      background: s.background,
      text: s.text,
      divider: s.divider,
      chart: s.chart,
    },
    // No webfont is loaded and none may be: the panel makes zero external
    // requests, so the stack is what the device already has. PingFang covers
    // the Chinese UI on Apple platforms; the generic fallbacks cover the rest.
    typography: {
      fontFamily: 'system-ui, -apple-system, "PingFang SC", sans-serif',
      fontSize: 15,
    },
    components: {
      // 44px is the touch-target floor the classic tree missed - its mode
      // buttons were ~28px tall. Set once here rather than per button, so a
      // new control cannot be born below the floor.
      MuiButton: {
        defaultProps: { size: "small", variant: "outlined" },
        styleOverrides: {
          root: { minHeight: 44, textTransform: "none" },
        },
      },
    },
  });
}

/* The operator's choice of scheme (the picker beside the language toggle):
   "system" follows the device - live, as it changes - and is what a panel
   with no stored choice does; "light" / "dark" override it until "system"
   is picked again. Storage can be unavailable (a locked-down browser); then
   the choice simply lasts for this page. */
const MODE_KEY = "panel_theme";
export const CHOICES = ["system", ...MODES];
export const DEVICE_QUERY = "(prefers-color-scheme: dark)";

export function initialChoice() {
  try {
    const stored = localStorage.getItem(MODE_KEY);
    if (MODES.includes(stored)) return stored;
  } catch {
    // storage unavailable: follow the device
  }
  return "system";
}

export function deviceMode() {
  const dark = typeof window !== "undefined" && window.matchMedia
    && window.matchMedia(DEVICE_QUERY).matches;
  return dark ? "dark" : "light";
}

export function rememberChoice(choice) {
  try {
    if (MODES.includes(choice)) localStorage.setItem(MODE_KEY, choice);
    else localStorage.removeItem(MODE_KEY);
  } catch {
    // storage unavailable: the choice lasts for this page only
  }
}
