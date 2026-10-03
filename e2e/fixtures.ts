import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { randomBytes } from "node:crypto";
import { test as base, expect, type Browser, type Page } from "@playwright/test";

export { expect };

/**
 * A signed-up user's page. The credentials never leave this process: never log them, never put
 * them in evidence.
 *
 * The SPA keeps the session in memory only, by design — `page.goto()` or `page.reload()` signs
 * the user out. Navigate by clicking, as a user would; when a case really means "after a
 * refresh", reload and then `logIn(actor)`.
 */
export interface Actor {
  page: Page;
  email: string;
  password: string;
}

/** Each actor gets its own browser context, so localStorage is never shared between them. */
async function newContextPage(browser: Browser, baseURL: string | undefined): Promise<Page> {
  const context = await browser.newContext({ baseURL });
  return context.newPage();
}

/** Signs up through the app's own form with a generated, throwaway account. */
export async function signUp(page: Page, label = "owner"): Promise<Actor> {
  const tag = randomBytes(4).toString("hex");
  const email = `tc-e2e-${label}-${tag}@example.test`;
  const password = `E2e-${randomBytes(9).toString("base64url")}`;
  await page.goto("/signup");
  await page.getByLabel("Name").fill(`E2E ${label} ${tag}`);
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByLabel("Confirm password").fill(password);
  await page.getByRole("button", { name: "Create account" }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  return { page, email, password };
}

/** Signs an actor back in after a reload or a direct navigation dropped the in-memory session. */
export async function logIn(actor: Actor): Promise<void> {
  const { page } = actor;
  if (!/\/login/.test(page.url())) await page.goto("/login");
  await page.getByLabel("Email").fill(actor.email);
  await page.getByLabel("Password", { exact: true }).fill(actor.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

/** Back to the dashboard without a page load, so the session survives. */
export async function goToDashboard(page: Page): Promise<void> {
  if (/\/dashboard$/.test(page.url())) return;
  await page.getByRole("link", { name: "← My lists" }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

function utcDatePlusDays(days: number): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + days));
}

/**
 * Creates a list from the dashboard and lands on its owner page. The expiry is picked in the
 * calendar the way a user would; `daysAhead` must be at least 1 (the picker's minDate).
 */
export async function createList(
  page: Page,
  name: string,
  { daysAhead = 14 }: { daysAhead?: number } = {},
): Promise<{ listId: string; shareUrl: string }> {
  await goToDashboard(page);
  await page.getByRole("button", { name: "+ New list" }).click();
  const dialog = page.getByRole("dialog", { name: "Create a new list" });
  await dialog.getByLabel("List name").fill(name);
  await dialog.getByRole("button", { name: /Expires|Pick a date/ }).click();

  const target = utcDatePlusDays(daysAhead);
  const dayLabel = `${target.getUTCDate()} ${target.toLocaleString("en-GB", { month: "long", timeZone: "UTC" })} ${target.getUTCFullYear()}`;
  const day = page.getByRole("button", { name: dayLabel, exact: true });
  // The calendar opens on the current month; step forward until the target day is shown.
  for (let i = 0; i < 24 && !(await day.isVisible()); i++) {
    await page.locator('[data-direction="next"]').first().click();
  }
  await day.click();

  await dialog.getByRole("button", { name: "Create list" }).click();
  await expect(page).toHaveURL(/\/lists\/[^/]+$/);
  const listId = page.url().split("/lists/")[1];
  const shareUrl = (await page.locator("code", { hasText: "/share/" }).innerText()).trim();
  return { listId, shareUrl };
}

/** Adds an item on the owner page and waits for it to appear in the list. */
export async function addItem(page: Page, name: string, url?: string): Promise<void> {
  await page.getByLabel("Item name").fill(name);
  if (url) await page.getByLabel("Link (optional)").fill(url);
  await page.getByRole("button", { name: "Add item" }).click();
  await expect(page.getByText(name, { exact: true })).toBeVisible();
}

/**
 * Saves a screenshot into the run's evidence folder as `<id>.png`. Use the case id plus a step,
 * e.g. `evidence(owner.page, "TC-GL-137-01-1")`. Without E2E_EVIDENCE (ad-hoc runs) it is a no-op.
 */
export async function evidence(page: Page, id: string): Promise<void> {
  const dir = process.env.E2E_EVIDENCE;
  if (!dir) return;
  mkdirSync(resolve(dir), { recursive: true });
  await page.screenshot({ path: join(resolve(dir), `${id}.png`), fullPage: true });
}

interface Fixtures {
  /** A freshly signed-up owner on the dashboard, in a context of their own. */
  owner: Actor;
  /** A second, unrelated signed-up user — "another user" in authorisation cases. */
  otherUser: Actor;
  /** An anonymous visitor in a context of their own. Call it again for a second guest. */
  newGuest: () => Promise<Page>;
}

export const test = base.extend<Fixtures>({
  owner: async ({ browser, baseURL }, use) => {
    const page = await newContextPage(browser, baseURL);
    await use(await signUp(page, "owner"));
    await page.context().close();
  },
  otherUser: async ({ browser, baseURL }, use) => {
    const page = await newContextPage(browser, baseURL);
    await use(await signUp(page, "other"));
    await page.context().close();
  },
  newGuest: async ({ browser, baseURL }, use) => {
    const pages: Page[] = [];
    await use(async () => {
      const page = await newContextPage(browser, baseURL);
      pages.push(page);
      return page;
    });
    for (const page of pages) await page.context().close();
  },
});
