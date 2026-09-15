# GiftList devenv

Orchestration for the local Docker Compose stack, and the scripts that keep files which must be
identical across repos identical. Everything runs in containers — no host .NET or Node is
required to run the system (see `../giftlist-web/README.md` and each service's `Dockerfile` for
what *is* useful to install for editor tooling).

```
cp .env.example .env    # optional — see .env.example for why
make up                 # build (if needed) and start the whole stack, detached
```

## The sibling-clone layout

Every build context and bind mount in `docker-compose.yml` points at a sibling of this repo, so
all seven clones plus the feed live in one directory (ARCHITECTURE.md "Packaging: local feed"):

```
giftlist/
  local-feed/              <- .nupkg and .tgz files land here; not a git repo
  giftlist-devenv/         <- you are here
  giftlist-buildingblocks/
  giftlist-gateway/
  giftlist-identity/
  giftlist-giftlists/
  giftlist-reservations/
  giftlist-web/
```

`clone-all.sh`, which creates that layout in one command, is GL-28 and does not exist yet; clone
the seven by hand until it does.

## `make up` does not work yet — what is still missing

The split (GL-25) converted every cross-repo `ProjectReference` into a `PackageReference` and
moved the SPA's protobuf generator into `giftlist-gateway`, which publishes the client as an npm
tarball. Nothing can restore until the feed exists and the containers can see it:

| Missing | Issue |
|---|---|
| Semantic versioning discipline and consumer pinning | GL-27 |
| `make pack-all` (dependency-ordered, refuses to overwrite a version already in the feed) and `clone-all.sh` | GL-28 |
| Per-repo CI | GL-30 |

GL-26 (each .NET repo's `nuget.config`) and GL-29 (the feed mounts in `docker-compose.yml`) have
landed, together and at the same mount point: every service, .NET or `web`, mounts the feed at
`- ../local-feed:/local-feed:ro`. An earlier cut gave the .NET services `/feed` instead, on the
theory that the in-container path could differ from the host's because a `nuget.config` is
configuration — true, but beside the point once a relative local source is understood to resolve
against the *declaring* `nuget.config`'s own directory rather than the CWD: `../local-feed` from
each repo's root already means the same thing everywhere. `docker-compose.yml`'s header has the
full account of why the split was undone.

## Keeping shared files identical across repos

Two scripts, same shape, both run from here because this is the only clone that can see all
seven. Both write a `.sha256` manifest that a test in each repo asserts against, so a hand-edited
copy fails the build instead of rotting quietly.

| Script | Canonical copy | Propagates | Checked by |
|---|---|---|---|
| `scripts/sync-repo-roots.sh` | `giftlist-buildingblocks/{Directory.Build.props,nuget.config}` | the other four .NET repo roots | `RepoRootFileSyncTests` |
| `scripts/sync-arch-tests.sh` | `giftlist-giftlists/tests/GiftLists.UnitTests/Architecture` | the other four `*.UnitTests/Architecture` folders | `ArchitectureTestSyncTests` |

Five repos, not seven: `giftlist-web` and this one contain no MSBuild project, so a
`Directory.Build.props` in either would be a file nothing reads.

Edit the canonical copy, run the script, then commit in **each repo it touched** — five commits
and five pull requests. That is the multi-repo cost ARCHITECTURE.md "The cost of multi-repo"
warns about, paid rather than denied.

Then check:

| URL | Expect |
|---|---|
| `http://localhost:5173` | SPA loads |
| `http://localhost:15672` | RabbitMQ management (guest/guest) |
| `http://localhost:8080/healthz/ready` | `Healthy` |
| `make ps` | every service `healthy` |

See `make help` for the full target list (`up`, `down`, `reset`, `restart`, `build`, `logs`, `ps`).

## Adding a dependency to `web`

`web`'s `node_modules` lives in a **named Docker volume** (`web-node-modules`), not the
`../giftlist-web:/app` bind mount — bind-mounted `node_modules` is slow enough on Docker Desktop hosts
to make this worth the extra moving part. The tradeoff: Docker only seeds a *new* named volume
from the image; an already-existing one is never refreshed by a plain `docker compose up`.

So `giftlist-web/docker-entrypoint.sh` reconciles the volume against
`giftlist-web/package-lock.json` **on every container start**: it hashes the lockfile, compares it to a
marker recorded inside the volume (`node_modules/.giftlist-lock-hash`) the last time `npm ci`
ran there, and reruns `npm ci` only when they differ. A match skips straight to `npm run dev`,
so the cost is paid only when the lockfile actually changed.

**What this means for you:** after `npm install`-ing a new dependency in `giftlist-web`, `make up` (or
`make restart`) reinstalls it automatically — you do not need to touch the volume by hand.
You'll see this in `docker logs giftlist-web`:

```
web entrypoint: package-lock.json hash changed since 'giftlist_web-node-modules' was
last reconciled (or it never has been) — running npm ci...
```

If it instead says `node_modules already matches package-lock.json — skipping npm ci`, nothing
changed and the container started from the existing volume as-is.

**If reconciliation itself fails** (e.g. no registry access), the container exits with a loud,
explicit error naming the volume and what to try next — it will not silently start with a
stale or partial `node_modules`, and the failure will not show up several steps later as some
unrelated "command not found" or "cannot find module" error. If you ever want to skip
reconciliation entirely and start over clean, `make reset` drops `web-node-modules` (and the
other named volumes) so the next `make up` reinstalls from scratch.

This is GL-58: before this entrypoint existed, a `web-node-modules` volume created before a
dependency was added to `package.json` would permanently shadow that dependency, and the only
symptom was the *unrelated* tool ending up missing at runtime (e.g. `sh: buf: not found` in `predev`, for the
`@bufbuild/buf` dependency added in GL-18) — nothing pointed at the volume. That particular
example is now historical: GL-25 moved the generator and its buf dependency to
`giftlist-gateway`. The volume hazard it illustrates is not.

## Where the .NET services build (and one thing not to change)

Each .NET service bind-mounts **its own repo** at `/src`. That was not always true: before the
split all four mounted the whole monorepo and every host referenced the shared `buildingblocks/`
projects, so two containers building `BuildingBlocks` at the same moment on a cold start raced on
the same files on the host — and `dotnet watch` does not retry after a build failure, so the
loser sat at "Fix the error to continue" forever, never becoming healthy, with `RestartCount=0`
because the process never exited.

That cross-service race is gone: no two containers share a path any more. Each service still
sets `ArtifactsPath=/build-output` (with `UseArtifactsOutput`) in `docker-compose.yml` and mounts
**its own named volume** there, for a smaller reason that survived the split — a container build
and a host `dotnet build` of the same repo would otherwise write to the same `bin`/`obj` through
the bind mount. Every container sees the same path string, but each is a distinct filesystem
outside the bind mount. `UseArtifactsOutput` also gives each *project* its
own subfolder, so a single shared `obj` never happens either. `make reset` drops these
`*-buildoutput` volumes along with the rest; a stale one costs a rebuild, never a wrong result.

**Do not set `ArtifactsPath` (or `BaseOutputPath` / `BaseIntermediateOutputPath`) in the repo-root
`Directory.Build.props`.** MSBuild takes an environment-derived property as an *ordinary*
property, so a `Directory.Build.props` assignment outranks it — which would quietly put all four
containers back on one path inside the bind mount, reinstating the race while the compose
comments still claimed isolation. That file is also copied into all five .NET repo roots by
`scripts/sync-repo-roots.sh` and pinned byte-for-byte by two architecture tests, so it is not the
place for this note — the next run of that script would revert it. If you want
artifacts output on the host as well, pass it as a **global** property (`-p:ArtifactsPath=...`).

This is GL-59, kept past the split it predicted would retire it. Read the compose comments the
same way: where they describe a cross-service hazard they are describing the old layout.

## Integration tests and container reuse

Every service's `*.IntegrationTests` suite starts its own Mongo and RabbitMQ via Testcontainers
(CONVENTIONS.md "Testing"). Locally, those containers default to `.WithReuse(true)` — a warm
container survives past the end of one `dotnet test` run so the next one skips the ~10–30s startup
cost. CI sets `CI=true`, which every fixture reads to turn reuse off, so CI always starts clean.

**Reuse and Testcontainers' own cleanup (Ryuk) are mutually exclusive — that is how the feature
is designed, not a bug in it.** A reused container has to survive the process that started it, so
nothing reaps it automatically. Nothing else in this repo used to remove these containers either
(GL-93): left alone, they accumulate for as long as the machine does — six-day-old containers were
found still attachable, and containers already `Exited` were silently restarted by the next
`dotnet test` run with no `make` target run in between.

Run `make reset-testcontainers` to reap them by hand — it removes every container carrying
Testcontainers' own `org.testcontainers=true` label, regardless of which suite started it or
whether `make up` has ever been run. Reach for it when disk or memory is tight, or when you
specifically want the next test run to start from a cold container (e.g. after changing a fixture
that only runs once per container's life, like an index or a seeded user). **It does not check
whether a suite is running against a container before removing it** — the same "any suite,
anywhere" filter that makes it thorough also means it will tear down a live run's containers (and
its Ryuk reaper, if CI-mode reuse-off created one) out from under it. Don't run it while a suite
you care about is mid-run.

**You should not need it just to get a hang to stop.** GL-93 found and fixed the actual defect:
Testcontainers.MongoDb's and Testcontainers.RabbitMq's default readiness checks read container
*history* (log lines since a `StoppedTime`/`CreatedTime` that a reused container carries from days
earlier), not the live server, so a reused container that has ever restarted could make
`WaitIndicateReadiness`'s exact-count comparison permanently false — an indefinite hang, bounded
only by Testcontainers' own one-hour internal timeout, in fixture initialization before the first
test ever ran. This is not a rare edge case: every fixture's `DisposeAsync` stops rather than
deletes the container, so the *second* local run of any suite is what first drives the count past
what the check will ever match again — "hung forever on every integration suite" is the ordinary
shape of a second run, not an unlucky restart. `BuildingBlocks.Testing.ReliableReadiness` replaces
both defaults with a live probe (`db.adminCommand({ping:1})` for Mongo; a compound
`check_running && check_local_alarms` for RabbitMQ, see below) on a bounded 30s timeout, so a
stale-but-healthy container attaches normally and a genuinely stuck or alarmed one now fails fast
— and, via `StartReliablyAsync`, loudly: the exception names the suite, the container and which
check never passed, rather than the bare `TimeoutException` the library throws on its own. See
that class's doc comment for the full mechanism, including the upstream issue this reproduces
(testcontainers-dotnet#1732, fixed for Mongo's replica-set path by #1735 but not for the
standalone path this codebase uses — confirmed still true in 4.15.0, the latest release).

**The RabbitMQ probe must run as the `rabbitmq` user, not root — this is GL-56, and it bit this
ticket's own fix once already.** `rabbitmq:3.13-management` sets no `USER`, so a bare
Testcontainers exec runs as root; only the server process itself is dropped to the `rabbitmq` uid
by the entrypoint's `gosu`. `rabbitmq-diagnostics` needs `/var/lib/rabbitmq/.erlang.cookie` for
Erlang distribution and creates it if missing, owned by whoever ran the command — a root probe
racing the server at container start can win and leave the cookie `root:root`, which the server
can then never read (`eacces`, `BOOT FAILED`, every test failing in the first few seconds). This
exact mechanism, and its fix, is already in this file's own rabbitmq healthcheck comment in
`docker-compose.yml` (`gosu rabbitmq rabbitmq-diagnostics -q ping`) — `ReliableReadiness`'s probe
now matches it. Do not drop the `gosu rabbitmq` prefix.

**The RabbitMQ probe also has to check for alarms, not just that the app is running.**
`check_running` alone exits 0 on a broker with an active resource alarm (verified: set with
`rabbitmqctl set_vm_memory_high_watermark`, `check_running` still passes, `check_local_alarms`
exits 69 and names the alarm) — and a memory-alarmed broker blocks publishers, so that gap would
have attached "ready" and relocated GL-93's hang into the Rebus host's first publish instead of
fixing it. The probe runs both (`check_running && check_local_alarms`, the "local" one because
every broker here is a single unclustered test node); a healthy broker still clears both in about
a second, so this does not trade a missed alarm for a false failure.

**Decision: reuse stays on by default locally.** The defect above was in the wait strategy, not
in reuse itself, and it is now fixed at the wait-strategy level rather than by giving up the
warm-container loop — `CI=true` (reuse off) was already proven reliable (72/72 integration tests,
~100s total across all three service suites) before this ticket, and stays the CI default
unconditionally. `make reset-testcontainers` exists for the cases a fixed wait strategy cannot
help with anyway — disk pressure, or a container whose on-disk state you deliberately want to
discard — not as a workaround for a hang, which should not recur.
