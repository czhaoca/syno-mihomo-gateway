import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// `base` is the URL prefix the app is SERVED from, and it must match the
// mount in app/main.py or every asset 404s while the page still renders -
// the failure mode that looks like a blank screen and reads like a JS error.
//
// /ui/next/ rather than /ui/: the classic panel at /ui/ is the one users
// have, and it keeps working until the rewrite item replaces it. Shipping a
// scaffold over a working UI would be a regression dressed as progress.
export default defineConfig({
  base: "/ui/next/",
  plugins: [react()],
  build: { outDir: "dist", emptyOutDir: true },
});
