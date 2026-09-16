#!/usr/bin/env bash
#
# Creates the sibling-clone layout every other script and docker-compose.yml assume: this repo
# (giftlist-devenv) plus the other six GiftList repos, cloned as siblings, with local-feed/
# alongside them (ARCHITECTURE.md "Packaging: local feed", README.md "The sibling-clone layout"):
#
#   giftlist/
#     local-feed/              <- created here, empty; not a git repo
#     giftlist-devenv/         <- this repo -- you already have it, that's how you're running this
#     giftlist-buildingblocks/
#     giftlist-gateway/
#     giftlist-identity/
#     giftlist-giftlists/
#     giftlist-reservations/
#     giftlist-web/
#
# HTTPS, not SSH: the goodsell-engineering org is public, so this needs no credentials and no key
# setup on a fresh machine -- the point of a one-command bootstrap.
#
# IDEMPOTENT BY SKIPPING, NOT BY UPDATING. A repo that already exists here is left exactly as it
# is -- not re-cloned, not pulled, not reset. This is a bootstrap script for a layout that does
# not exist yet, not a sync tool for one that does; use each repo's own `git pull` (or `git
# status` first, if you're not sure what's in it) once it's there. That also makes an interrupted
# first run safe to just re-run.
#
# Usage:
#   scripts/clone-all.sh
#
# Then: make pack-all (fills local-feed/), then make up.

set -euo pipefail

readonly org_url="https://github.com/goodsell-engineering"

# The directory this repo's parent lives in -- i.e. where the other six repos and local-feed
# belong as siblings of giftlist-devenv.
readonly workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

readonly repos=(
  giftlist-buildingblocks
  giftlist-identity
  giftlist-giftlists
  giftlist-reservations
  giftlist-gateway
  giftlist-web
)

clone_repo() {
  local repo="$1"
  local dest="${workspace}/${repo}"

  if [[ -d "${dest}" ]]; then
    echo "Skipping ${repo}: ${dest} already exists."
    return
  fi

  echo "Cloning ${repo}..."
  git clone "${org_url}/${repo}.git" "${dest}"
}

main() {
  local repo
  for repo in "${repos[@]}"; do
    clone_repo "${repo}"
  done

  local feed_dir="${workspace}/local-feed"
  if [[ -d "${feed_dir}" ]]; then
    echo "local-feed/ already exists at ${feed_dir} -- leaving it alone."
  else
    echo "Creating ${feed_dir} (not a git repo -- pack-all's .nupkg/.tgz output lands here)."
    mkdir -p "${feed_dir}"
  fi

  echo ""
  echo "Done. Layout is at ${workspace}."
  echo "Next: make pack-all   (packs the BuildingBlocks family, the *.Contracts packages and"
  echo "                       the Gateway's npm client into local-feed/)"
  echo "Then: make up"
}

main "$@"
