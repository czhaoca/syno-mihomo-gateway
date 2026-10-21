import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import CssBaseline from "@mui/material/CssBaseline";
import { ThemeProvider } from "@mui/material/styles";

import App from "./App.jsx";
import {
  DEVICE_QUERY, deviceMode, initialChoice, makeTheme, rememberChoice,
} from "./theme.js";

/* The scheme lives above the theme provider, so switching it rebuilds the
   theme once and every component re-reads its tokens. The document carries
   it too (`data-theme`, and `color-scheme` for native controls and
   scrollbars), which is what the browser specs read. While the choice is
   "system" the device's preference is followed as it changes, not only at
   load. */
function Root() {
  const [choice, setChoice] = useState(initialChoice);
  const [device, setDevice] = useState(deviceMode);
  useEffect(() => {
    if (!window.matchMedia) return undefined;
    const query = window.matchMedia(DEVICE_QUERY);
    const follow = () => setDevice(query.matches ? "dark" : "light");
    query.addEventListener("change", follow);
    return () => query.removeEventListener("change", follow);
  }, []);
  const mode = choice === "system" ? device : choice;
  const theme = useMemo(() => makeTheme(mode), [mode]);
  useEffect(() => {
    document.documentElement.dataset.theme = mode;
    document.documentElement.style.colorScheme = mode;
  }, [mode]);
  const changeChoice = (next) => {
    rememberChoice(next);
    setChoice(next);
  };
  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <App choice={choice} onChoice={changeChoice} />
    </ThemeProvider>
  );
}

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
);
