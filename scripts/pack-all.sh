#!/usr/bin/env bash
#
# Packs every GiftList package this workspace produces -- the BuildingBlocks family, the three
# *.Contracts packages, and the Gateway's generated npm client -- into ../local-feed, in
# dependency order, and refuses to overwrite a version already sitting there.
#
# WHY THE OVERWRITE GUARD IS NOT OPTIONAL. NuGet (and npm) cache by (id, version). Repacking an
# unchanged version number over different content does not error -- it silently leaves every
# consumer that has ever restored that version on the old, stale contract, forever, on that
# machine. ARCHITECTURE.md "Packaging: local feed" and CONVENTIONS.md's contract-change procedure
# both name this as the single most likely way to lose a day in this phase. The fix is always the
# same: bump <Version> (or package.json's "version") and re-run. THERE IS NO FLAG TO BYPASS THIS.
# Deleting the file from local-feed to get around it defeats the entire point -- see this
# project's giftlist-contract-change skill and just bump the version instead.
#
# DEPENDENCY ORDER, AND WHY IT BARELY MATTERS BUT IS KEPT ANYWAY. Every package below is
# self-contained at pack time: BuildingBlocks.Infrastructure depends on BuildingBlocks via an
# ordinary in-repo ProjectReference (resolved from source, not from the feed), and all three
# *.Contracts projects reference nothing per CONVENTIONS.md "Project reference graph". So packing
# order cannot actually break a `dotnet pack` here. It is still fixed and dependency-first --
# BuildingBlocks, then BuildingBlocks.Infrastructure and BuildingBlocks.Testing (both consumed by
# every service), then the three *.Contracts packages (consumed by their subscribers and by the
# Gateway, which references all three) -- because that is the order a human reasons about the
# graph in, and a script that packed in a different order every run would be one more thing to
# double-check when a pack fails partway through. The npm client is entirely independent of the
# .NET graph, so it packs last.
#
# WHAT THIS DOES NOT DO: restore consumers. Filling the feed is this script's whole job; each
# service's own `dotnet restore` / `npm install` is a separate step (see each repo's README).
#
# Usage:
#   scripts/pack-all.sh

set -euo pipefail

# The directory holding all seven sibling clones: the parent of giftlist-devenv.
readonly workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly local_feed="${workspace}/local-feed"

# Dependency-ordered list of packable .csproj files -- see the header comment for why this order
# is chosen even though nothing here would break in a different one.
readonly dotnet_packages=(
  "giftlist-buildingblocks/src/BuildingBlocks/BuildingBlocks.csproj"
  "giftlist-buildingblocks/src/BuildingBlocks.Infrastructure/BuildingBlocks.Infrastructure.csproj"
  "giftlist-buildingblocks/src/BuildingBlocks.Testing/BuildingBlocks.Testing.csproj"
  "giftlist-identity/src/Identity.Contracts/Identity.Contracts.csproj"
  "giftlist-giftlists/src/GiftLists.Contracts/GiftLists.Contracts.csproj"
  "giftlist-reservations/src/Reservations.Contracts/Reservations.Contracts.csproj"
)

readonly npm_client_dir="giftlist-gateway/clients/typescript"

# The sibling repos every package above lives in, checked up front so a missing clone fails once,
# clearly, before any packing starts -- rather than however far through the list happens to reach
# the first missing one.
readonly required_repos=(
  giftlist-buildingblocks
  giftlist-identity
  giftlist-giftlists
  giftlist-reservations
  giftlist-gateway
)

fail() {
  echo "" >&2
  echo "pack-all: $1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required on the host to pack, and was not found on PATH."
}

check_siblings_present() {
  local repo
  for repo in "${required_repos[@]}"; do
    if [[ ! -d "${workspace}/${repo}" ]]; then
      fail "sibling clone missing: ${workspace}/${repo}
Run scripts/clone-all.sh first (see README.md \"The sibling-clone layout\")."
    fi
  done
}

# Reads a single top-level element's text content out of a .csproj by name -- these files are our
# own, hand-written and one element per line (see e.g. Identity.Contracts.csproj), so a targeted
# grep is simpler and far cheaper than spinning up another MSBuild evaluation per lookup, which
# matters when several agents are packing concurrently on a memory-constrained box.
read_xml_element() {
  local element="$1" file="$2"
  grep -oP "(?<=<${element}>)[^<]+" "${file}" | head -n1
}

# Refuses to proceed if the given filename already exists in the feed -- the overwrite guard.
# Takes the fully-formed filename (not id/version separately) so it reads identically for the
# .nupkg and .tgz callers below.
guard_against_overwrite() {
  local filename="$1" description="$2"
  local path="${local_feed}/${filename}"
  if [[ -f "${path}" ]]; then
    fail "${description} already exists in the feed: ${path}
NuGet/npm cache by (id, version); repacking the same version would silently leave every consumer
that has already restored it on stale content. Bump the version and try again -- do not delete
this file to get around the guard (CONVENTIONS.md's contract-change procedure, giftlist-contract-change skill)."
  fi
}

pack_dotnet_package() {
  local relative_csproj="$1"
  local csproj="${workspace}/${relative_csproj}"

  [[ -f "${csproj}" ]] || fail "expected project file not found: ${csproj}"

  local package_id version
  package_id="$(read_xml_element "PackageId" "${csproj}")"
  version="$(read_xml_element "Version" "${csproj}")"
  [[ -n "${package_id}" ]] || fail "could not read <PackageId> from ${csproj}"
  [[ -n "${version}" ]] || fail "could not read <Version> from ${csproj}"

  guard_against_overwrite "${package_id}.${version}.nupkg" "${package_id} ${version}"

  echo "Packing ${package_id} ${version} (${relative_csproj})..."
  # -nodeReuse:false -p:UseSharedCompilation=false -m:1: several agents/services build
  # concurrently on a memory-constrained box; a lingering MSBuild worker node or the shared
  # compiler server is exactly the kind of background process that turns a tight box into an
  # "Internal CLR error".
  dotnet pack "${csproj}" \
    --configuration Release \
    --output "${local_feed}" \
    --verbosity minimal \
    -nodeReuse:false \
    -p:UseSharedCompilation=false \
    -m:1
}

pack_npm_client() {
  local client_dir="${workspace}/${npm_client_dir}"
  local package_json="${client_dir}/package.json"

  [[ -f "${package_json}" ]] || fail "expected package.json not found: ${package_json}"
  require_command npm
  require_command node

  local name version tarball_name
  name="$(node -p "require('${package_json}').name")"
  version="$(node -p "require('${package_json}').version")"
  # npm's own tarball-naming rule: strip a leading "@scope/" slash by turning it into a dash, and
  # drop the "@". Matches what `npm pack` actually writes -- verified against the file already in
  # local-feed (giftlist-gateway-client-0.1.0.tgz) for @giftlist/gateway-client.
  tarball_name="$(echo "${name}" | sed -E 's#^@##; s#/#-#')-${version}.tgz"

  guard_against_overwrite "${tarball_name}" "${name} ${version}"

  echo "Packing ${name} ${version} (${npm_client_dir})..."
  (
    cd "${client_dir}"
    npm install --no-audit --no-fund
    # prepack runs `npm run build` (buf generate + tsc) for us, so this can never ship a stale
    # client -- see giftlist-gateway/clients/typescript/README.md.
    npm pack --pack-destination "${local_feed}"
  )
}

main() {
  require_command dotnet
  check_siblings_present
  mkdir -p "${local_feed}"

  local relative_csproj
  for relative_csproj in "${dotnet_packages[@]}"; do
    pack_dotnet_package "${relative_csproj}"
  done

  pack_npm_client

  echo ""
  echo "pack-all: done. Feed contents:"
  ls -1 "${local_feed}"
}

main "$@"
