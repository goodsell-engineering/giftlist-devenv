import { test, expect, createList, addItem, evidence } from "../fixtures.js";

// Proves the harness against the running stack: sign up, create a list, add an item, and open
// the share link as an anonymous guest in a separate context.
test("owner shares a list and a guest sees its items", async ({ owner, newGuest }) => {
  const { shareUrl } = await createList(owner.page, "E2E smoke list");
  await addItem(owner.page, "Board game");
  await evidence(owner.page, "smoke-owner-page");

  const guest = await newGuest();
  await guest.goto(shareUrl);
  await expect(guest.getByText("Board game", { exact: true })).toBeVisible();
  await expect(guest.getByRole("button", { name: /reserve/i }).first()).toBeVisible();
  await evidence(guest, "smoke-guest-view");
});
