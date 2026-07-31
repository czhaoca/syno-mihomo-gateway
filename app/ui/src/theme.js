import { createTheme } from "@mui/material/styles";

/* The width at which the audit log stops being a stack of cards and becomes
   a table. 760px rather than one of MUI's defaults because that is the
   threshold the classic stylesheet already tuned against the real five-column
   log; moving it would change behaviour on mid-size tablets for no stated
   reason. */
export const FOLD_PX = 760;

export const theme = createTheme({
  palette: {
    primary: { main: "#2563eb" },
    success: { main: "#16a34a" },
    warning: { main: "#d97706" },
    error: { main: "#dc2626" },
    background: { default: "#f6f8fa", paper: "#ffffff" },
    text: { primary: "#1b2733", secondary: "#52606d" },
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
