import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// `base` is the URL prefix the app is SERVED from, and it must match the
// mount in app/main.py or every asset 404s while the page still renders -
// the failure mode that looks like a blank screen and reads like a JS error.
//
// /ui/ since #80: this tree IS the panel now. It was mounted additively at
// /ui/next/ for exactly one item, while it was still a scaffold and the
// classic tree was the UI users had; the rewrite that replaced that tree
// moved the mount, the base and the browser gate together.
export default defineConfig({
  base: "/ui/",
  plugins: [react()],
  build: { outDir: "dist", emptyOutDir: true },
});
