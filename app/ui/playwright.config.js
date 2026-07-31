import { defineConfig, devices } from "@playwright/test";

// The app under test is the REAL panel: scripts/ci/ui_e2e_server.py starts
// uvicorn against the same FakeController the API e2e already uses, rather
// than a second fake that would drift from it.
//
// PANEL_E2E_PORT is fixed rather than discovered, because Playwright needs
// the URL before the server prints one.
const PORT = process.env.PANEL_E2E_PORT || "8799";
const PYTHON = process.env.PANEL_E2E_PYTHON || "python3";

export default defineConfig({
  testDir: "./e2e",
  // A browser suite that retries is a browser suite that hides a race. If
  // something here is flaky it is a defect in the page or in the spec, and
  // both are worth failing on.
  retries: 0,
  workers: 1,
  reporter: process.env.CI ? "list" : "line",
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: "off",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
  ],
  webServer: {
    command: `${PYTHON} ../../scripts/ci/ui_e2e_server.py`,
    url: `http://127.0.0.1:${PORT}/health`,
    env: { PANEL_E2E_PORT: PORT },
    reuseExistingServer: false,
    timeout: 60_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
