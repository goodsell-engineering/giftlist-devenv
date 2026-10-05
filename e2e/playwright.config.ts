import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "@playwright/test";

const here = dirname(fileURLToPath(import.meta.url));

// The SPA calls the gateway at PUBLIC_HOST (docker-compose.yml), so the browser has to load the
// SPA from that same host or every command fails CORS. Read it from the human's .env rather than
// assuming localhost; E2E_BASE_URL overrides both.
function publicHost(): string {
  try {
    const env = readFileSync(join(here, "..", ".env"), "utf8");
    const line = env.split("\n").find((l) => l.startsWith("PUBLIC_HOST="));
    const value = line?.slice("PUBLIC_HOST=".length).trim();
    if (value) return value;
  } catch {
    // No .env: compose falls back to localhost, and so do we.
  }
  return "localhost";
}

const evidenceDir = process.env.E2E_EVIDENCE ? resolve(process.env.E2E_EVIDENCE) : undefined;

export default defineConfig({
  testDir: process.env.E2E_SPECS ? resolve(process.env.E2E_SPECS) : join(here, "tests"),
  // One worker: every spec shares one stack, and evidence is easier to read in case order.
  workers: 1,
  fullyParallel: false,
  retries: 0,
  // A flaky pass must be reported as flaky, not retried into a PASS.
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: evidenceDir
    ? [["list"], ["json", { outputFile: join(evidenceDir, "playwright-results.json") }]]
    : [["list"]],
  // Traces and automatic failure screenshots stay here, outside the evidence folder: a trace
  // records request headers, and those carry JWTs.
  outputDir: join(here, "test-results"),
  use: {
    baseURL: process.env.E2E_BASE_URL ?? `http://${publicHost()}:5173`,
    // The installed Google Chrome — nothing to download.
    channel: "chrome",
    headless: process.env.E2E_HEADED !== "1",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    viewport: { width: 1280, height: 900 },
  },
});
