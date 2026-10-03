# e2e — Playwright against the running stack

Drives the SPA in a real browser against whatever `make up` is running. There are two uses:

- **Acceptance runs** (`/test-ticket`): the test runner writes one spec per acceptance case into
  the run's own folder (`sdlc/<KEY>/test-runs/<n>/e2e/`). It runs them here and saves
  screenshots into the run's `evidence/`.
- **Standing journeys** in `tests/`. Today that is only the smoke spec; the full journeys
  (ARCHITECTURE.md, "Testing") belong here as they are written.

## Setup

```bash
make e2e-install        # npm ci in e2e/
```

It uses the **installed Google Chrome** (`channel: "chrome"`), so there is no browser download.
Node 22 or later is needed, the same as `pack-all`.

## Running

```bash
make up                                   # the stack must be up and healthy
make e2e                                  # run tests/
make e2e SPECS=/abs/path/to/run/e2e EVIDENCE=/abs/path/to/run/evidence
make e2e ARGS="--grep TC-GL-137-01"      # any Playwright CLI arguments
E2E_HEADED=1 make e2e                     # watch it
```

`SPECS` is copied into `e2e/runs/`, which is gitignored and replaced on every run. That way the
specs resolve this folder's `node_modules` and `fixtures.ts`. Specs import
`../fixtures.js`, the same path from `runs/` and from `tests/`.

**Base URL.** The SPA calls the gateway at `PUBLIC_HOST` from `../.env`. The browser must load the
SPA from the same host, or every command fails CORS, so the config reads `PUBLIC_HOST` (default
`localhost`) and uses `http://$PUBLIC_HOST:5173`. Set `E2E_BASE_URL` to override it, for example
when running from a worktree that has no `.env`.

## Writing a spec

```ts
import { test, expect, createList, addItem, evidence } from "../fixtures.js";

test("TC-GL-131-03 second guest cannot reserve an already-reserved item", async ({ owner, newGuest }) => {
  const { shareUrl } = await createList(owner.page, "Birthday");
  await addItem(owner.page, "Board game");

  const guestA = await newGuest();
  const guestB = await newGuest();          // its own context, so its own localStorage
  // …
  await evidence(guestB, "TC-GL-131-03-1");  // → $EVIDENCE/TC-GL-131-03-1.png
});
```

| Fixture or helper | Gives you |
|---|---|
| `owner`, `otherUser` | a freshly signed-up user (generated throwaway account) in a context of its own |
| `newGuest()` | an anonymous page in a new context; call it once per guest |
| `signUp(page, label)` | the sign-up flow, for a case that needs more users |
| `logIn(actor)` | signs an actor back in after a reload |
| `goToDashboard(page)` | back to the dashboard by clicking, so the session survives |
| `createList(page, name, { daysAhead })` | a list created through the dashboard and its expiry picker; returns `listId` and `shareUrl` |
| `addItem(page, name, url?)` | an item added on the owner page |
| `evidence(page, id)` | a full-page screenshot saved as `<id>.png` in `EVIDENCE` |

- **One case, one test**, named with the case id first so `--grep` finds it.
- **The session lives in memory only**, by design, so `page.goto()` or `page.reload()` signs a
  user out. Navigate by clicking. When a case really means "after a refresh", reload and then
  `logIn(actor)`. Guests have no session, so reloading a guest page is fine.
- **Wait on what the user would see** (`expect(...).toBeVisible()`, `toHaveText`), never on a
  fixed timeout. Playwright's assertions already poll, up to 10 s here.
- Set preconditions up through the product, as the fixtures do. Mongo, RabbitMQ and log checks
  stay in the runner's shell commands next to the spec.

## What never leaves this folder

Traces and automatic failure screenshots go to `e2e/test-results/` (gitignored), not to
`EVIDENCE`. A trace records request headers, and they carry JWTs. Only screenshots a spec takes
with `evidence()` and the JSON results file are written to the evidence folder. Never screenshot
devtools storage.
