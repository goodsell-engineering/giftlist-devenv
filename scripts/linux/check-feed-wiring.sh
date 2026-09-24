#!/usr/bin/env bash
#
# GL-30: fails cheaply if docker-compose.yml's local-feed wiring ever drifts.
#
# WHY THIS EXISTS. Nothing tests the feed mount, in any environment (Batch 30 review): every
# claim made about the feed was a hand-run probe, deleted afterwards. GL-26 (nuget.config) and
# GL-29 (these mounts) settled on ONE path, `/local-feed`, used by every one of the five services
# that need it (identity, giftlists, reservations, gateway, web) -- see this file's own header
# comment in docker-compose.yml for why `/feed` was tried and rejected. Nothing mechanical has
# asserted that settlement holds since.
#
# WHY `docker compose config` IS ENOUGH, AND WHY IT NEEDS NO STACK. `config` renders the compose
# file with every interpolation and merge applied -- env var defaults, YAML anchors
# (x-dotnet-env, x-dotnet-healthcheck), the lot -- without starting or even validating that any
# image, container or sibling directory exists. Verified empirically while writing this script:
# `docker compose config` succeeds from a lone checkout of this repo with none of the six sibling
# directories present (no giftlist-identity, no local-feed, nothing) -- `context:`/`source:`
# paths are resolved to strings, never checked against the filesystem, at `config` time. That is
# what makes this check cheap enough to run on every push: no Testcontainers slot, no `make up`,
# no siblings to check out, just this one repo and the `docker` CLI GitHub-hosted runners already
# ship.
#
# WHAT IT ASSERTS, EXACTLY:
#   1. No service mounts a bare /feed path. An earlier cut of GL-29 used /feed for the four .NET
#      services and /local-feed for web; that split was undone on purpose (see
#      docker-compose.yml's header) and must never come back silently.
#   2. Every service that restores or installs from the feed --
#      identity/giftlists/reservations/gateway/web -- mounts it at exactly /local-feed.
#
# It does NOT start a container, does NOT need the Docker daemon to be doing anything beyond
# answering `compose config` (no build, no pull, no run), and does NOT check that any sibling
# repo or the feed directory itself exists on disk -- that is what the stack's own `make up`
# proves, at a cost (Testcontainers-adjacent load, a running daemon) this check exists to avoid
# paying just to answer a much narrower question.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

EXPECTED_SERVICES=(identity giftlists reservations gateway web)

CONFIG_JSON="$(docker compose config --format json)"

fail=0

# 1. No bare /feed mount, anywhere.
bare_feed_hits="$(echo "$CONFIG_JSON" | jq -c '
  [.services | to_entries[] | .key as $svc | (.value.volumes // [])[] |
    select(.target == "/feed") | {service: $svc, target, source}]
')"
if [ "$(echo "$bare_feed_hits" | jq 'length')" -gt 0 ]; then
  echo "FAIL: found a bind mount targeting the bare /feed path. The feed lives at /local-feed" >&2
  echo "      only (GL-29) -- a second mount point must not come back." >&2
  echo "$bare_feed_hits" | jq '.' >&2
  fail=1
else
  echo "OK: no service mounts a bare /feed path."
fi

# 2. Every expected service mounts /local-feed.
missing=()
for svc in "${EXPECTED_SERVICES[@]}"; do
  count="$(echo "$CONFIG_JSON" | jq --arg svc "$svc" '
    [(.services[$svc].volumes // [])[] | select(.target == "/local-feed")] | length
  ')"
  if [ "$count" -lt 1 ]; then
    missing+=("$svc")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "FAIL: expected a /local-feed mount on each of: ${EXPECTED_SERVICES[*]}" >&2
  echo "      Missing on: ${missing[*]}" >&2
  fail=1
else
  echo "OK: /local-feed mounted on: ${EXPECTED_SERVICES[*]}"
fi

exit "$fail"
