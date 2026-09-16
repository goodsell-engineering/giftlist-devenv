#!/usr/bin/env bash
#
# Packs every GiftList package this workspace produces -- the BuildingBlocks family, the three
# *.Contracts packages, and the Gateway's generated npm client -- into ../local-feed, in
# dependency order. Safe to run repeatedly: a package whose freshly-built content matches what is
# already in the feed is skipped, and the command still exits 0. A package whose content differs
# from what is already in the feed AT THE SAME VERSION still fails hard -- see GL-100 below.
#
# WHY THE OVERWRITE GUARD IS NOT OPTIONAL. NuGet (and npm) cache by (id, version). Repacking an
# unchanged version number over different content does not error -- it silently leaves every
# consumer that has ever restored that version on the old, stale contract, forever, on that
# machine. ARCHITECTURE.md "Packaging: local feed" and the giftlist-contract-change skill both
# name this as the single most likely way to lose a day in this phase. The fix is always the
# same: bump <Version> (or package.json's "version") and re-run. THERE IS NO FLAG TO BYPASS THIS.
# Deleting the file from local-feed to get around it defeats the entire point -- see this
# project's giftlist-contract-change skill and just bump the version instead.
#
# GL-100: SKIP-IF-UNCHANGED, NOT JUST REFUSE. Before this, the guard fired on the first artifact
# already in the feed, full stop -- which made `make pack-all` a once-only command, because every
# run after the first died on the earliest unrelated package (BuildingBlocks 0.1.0) before ever
# reaching whatever you actually bumped. That's not a hypothetical: it blocked GL-4's own exit
# criterion, twice. Every package below is now packed into a scratch directory first, THEN
# compared against whatever the feed already holds at that (id, version):
#   - nothing there yet                 -> move the scratch artifact into the feed. New version.
#   - same content already there        -> discard the scratch artifact, log a skip, move on.
#     This is what makes a second `make pack-all` a no-op instead of a crash.
#   - DIFFERENT content already there   -> fail hard, exactly as before. The feed is left
#     untouched -- the scratch artifact is discarded, never moved over the existing file. This is
#     the one case the guard exists for at all (a forgotten version bump), and GL-100 does not
#     weaken it: it only stops the guard firing on packages nobody touched.
#
# WHAT "SAME CONTENT" MEANS, AND WHY IT'S TWO DIFFERENT CHECKS. A .nupkg and a .tgz are both
# zip-family archives, and naive whole-file byte comparison ("just sha256sum the two files") was
# tried against this workspace's own packages before picking the approach below -- see each
# digest function for what was actually measured:
#   - .tgz (npm pack): whole-file sha256 IS stable across runs of identical source -- verified by
#     packing @giftlist/gateway-client twice in a row with nothing changed and diffing the
#     tarballs byte-for-byte identical, matching npm's own printed `shasum`/`integrity` lines.
#     npm normalises tar entry metadata for exactly this reason. So the .tgz check is plain
#     whole-file byte identity; see tgz_content_digest.
#   - .nupkg (dotnet pack): whole-file sha256 is NOT stable, for two independent reasons, both
#     found by packing the SAME BuildingBlocks source twice and diffing the results rather than
#     assumed:
#       1. The NuGet/OPC packer regenerates two container-bookkeeping entries with a fresh random
#          identifier on every single pack, unconditionally, regardless of content: the metadata
#          part `package/services/metadata/core-properties/*.psmdcp` (the GUID-shaped filename
#          itself changes every run, even though the file's own contents don't) and `_rels/.rels`
#          (which both references that filename and carries its own randomly-generated
#          relationship id for it). Neither carries information a consumer's build could ever
#          observe. Excluded from the digest entirely; see nupkg_content_digest.
#       2. The .NET SDK's default SourceLink-style behaviour embeds `git rev-parse HEAD` for the
#          WHOLE containing repo -- confirmed by packing literally the same BuildingBlocks source
#          at two different commits of giftlist-buildingblocks and diffing the results -- into
#          both the .nuspec (`<repository commit="...">`) and the compiled assembly's
#          AssemblyInformationalVersion (as a "+<40 hex chars>" suffix baked into the .dll). That
#          suffix does not just make the .nuspec text differ: because it is embedded via a
#          generated AssemblyInfo.cs, it becomes a compiler INPUT, so it also changes the
#          resulting IL's module version id (MVID) -- a stray textual substitution over the raw
#          bytes cannot repair that. That commit describes "what commit was HEAD when this was
#          built", not "what this package's own source is": a commit to a completely unrelated
#          file anywhere else in the repo moves it just as much as a change to this package
#          would. Comparing it would make a repeat `make pack-all` refuse every time the repo has
#          advanced at all -- exactly the "unusable a second time" failure GL-100 exists to fix,
#          just relocated one level down. Fixed at the source instead of papered over at compare
#          time: `dotnet pack` below is given `-p:EnableSourceControlManagerQueries=false`, which
#          stops the SDK querying git at all, so the .dll and .nuspec it produces depend only on
#          this package's own source -- verified by rebuilding BuildingBlocks from clean twice
#          with the flag set and diffing every entry (nuspec, [Content_Types].xml, .dll) byte-
#          identical, where without it only the .nuspec/.dll had differed.
#     Once both of the above are accounted for -- entries 1 skipped, cause 2 prevented from
#     happening at all -- every remaining entry in the .nupkg is byte-identical across repeated
#     packs of the same source. So the check is: skip the two bookkeeping entries, hash everything
#     else by name and content, sorted so entry order can't matter. See nupkg_content_digest. This
#     asymmetry between the two artifact kinds is deliberate, not an oversight: dotnet pack and
#     npm pack just don't offer the same reproducibility guarantee out of the box.
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

# Content digest for a .nupkg -- see the header comment ("WHAT 'SAME CONTENT' MEANS") for what
# this excludes and why: the two randomly-named OPC bookkeeping entries NuGet regenerates on
# every pack regardless of content. (The other source of noise found during design -- the
# embedded git commit -- is prevented at pack time instead, via -p:EnableSourceControlManagerQueries=false
# on the `dotnet pack` call below, so there is nothing left to normalise here.) Implemented in
# Python rather than unzip/sha256sum because unzip's extraction argument is a glob pattern, not a
# literal name, and silently fails to match entries like "[Content_Types].xml" that contain glob
# metacharacters. python3 is assumed present on the host alongside dotnet/npm/node -- see
# README.md "Packing prerequisites".
nupkg_content_digest() {
  python3 - "$1" <<'PY'
import hashlib, re, sys, zipfile

path = sys.argv[1]
digest = hashlib.sha256()
with zipfile.ZipFile(path) as zf:
    names = sorted(
        name for name in zf.namelist()
        if name != "_rels/.rels"
        and not re.match(r"^package/services/metadata/core-properties/.*\.psmdcp$", name)
    )
    for name in names:
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(zf.read(name)).digest())
print(digest.hexdigest())
PY
}

# Content digest for a .tgz -- see the header comment for why this one is plain whole-file
# byte identity (verified stable across repeated `npm pack` runs of identical source), unlike
# the .nupkg case above.
tgz_content_digest() {
  sha256sum "$1" | cut -d' ' -f1
}

# The feed-placement decision, shared by both package kinds. `scratch_artifact` is the
# freshly-built file, not yet in the feed; `feed_path` is where it would live; `digest_fn` names
# the digest function (nupkg_content_digest or tgz_content_digest) appropriate to its kind.
#
#   - feed_path does not exist yet:            move scratch_artifact into place. New version.
#   - feed_path exists, digests match:         discard scratch_artifact, log a skip, return 0.
#   - feed_path exists, digests differ:        discard scratch_artifact, fail hard. The feed is
#     never overwritten by this function -- see the GL-100 paragraph in the header comment.
place_or_skip_or_fail() {
  local scratch_artifact="$1" feed_path="$2" description="$3" digest_fn="$4"

  if [[ ! -f "${feed_path}" ]]; then
    mv "${scratch_artifact}" "${feed_path}"
    echo "  ${description}: packed"
    return 0
  fi

  local new_digest existing_digest
  new_digest="$("${digest_fn}" "${scratch_artifact}")"
  existing_digest="$("${digest_fn}" "${feed_path}")"

  if [[ "${new_digest}" == "${existing_digest}" ]]; then
    rm -f "${scratch_artifact}"
    echo "  ${description}: unchanged, already in the feed -- skipping"
    return 0
  fi

  rm -f "${scratch_artifact}"
  fail "${description} already exists in the feed with DIFFERENT content: ${feed_path}
NuGet/npm cache by (id, version); repacking the same version with different content would
silently leave every consumer that has already restored it on stale content. Bump the version
and try again -- do not delete this file to get around the guard (giftlist-contract-change
skill, ARCHITECTURE.md \"What 'breaking' means for a message contract\")."
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

  local filename="${package_id}.${version}.nupkg"
  local scratch
  scratch="$(mktemp -d)"

  echo "Packing ${package_id} ${version} (${relative_csproj})..."
  # -nodeReuse:false -p:UseSharedCompilation=false -m:1: several agents/services build
  # concurrently on a memory-constrained box; a lingering MSBuild worker node or the shared
  # compiler server is exactly the kind of background process that turns a tight box into an
  # "Internal CLR error".
  # -p:EnableSourceControlManagerQueries=false: stops the SDK embedding `git rev-parse HEAD` into
  # the .nuspec and the compiled assembly -- see the header comment ("WHAT 'SAME CONTENT' MEANS",
  # point 2). Without it, the artifact this produces would depend on which commit the repo
  # happens to be at right now, not just on this package's own source.
  # Packed into a scratch dir, not straight into the feed -- see place_or_skip_or_fail, which
  # decides whether it belongs there.
  dotnet pack "${csproj}" \
    --configuration Release \
    --output "${scratch}" \
    --verbosity minimal \
    -nodeReuse:false \
    -p:UseSharedCompilation=false \
    -p:EnableSourceControlManagerQueries=false \
    -m:1

  [[ -f "${scratch}/${filename}" ]] || fail "dotnet pack did not produce the expected artifact: ${scratch}/${filename}"

  place_or_skip_or_fail "${scratch}/${filename}" "${local_feed}/${filename}" "${package_id} ${version}" nupkg_content_digest
  rm -rf "${scratch}"
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

  local scratch
  scratch="$(mktemp -d)"

  echo "Packing ${name} ${version} (${npm_client_dir})..."
  (
    cd "${client_dir}"
    # `npm ci`, not `npm install`: matches how the rest of this workspace treats a lockfile as
    # authoritative (giftlist-web's own CI installs the same way). `npm install` can float this
    # project's ^-ranged buf/protobuf devDependencies onto a newer version than
    # package-lock.json pins, silently changing what buf generates; `npm ci` installs exactly
    # what the lockfile says and fails loudly instead if package.json and the lockfile have
    # drifted apart.
    npm ci --no-audit --no-fund
    # prepack runs `npm run build` (buf generate + tsc) for us, so this can never ship a stale
    # client -- see giftlist-gateway/clients/typescript/README.md. Packed into a scratch dir, not
    # straight into the feed -- see place_or_skip_or_fail, which decides whether it belongs there.
    npm pack --pack-destination "${scratch}"
  )

  [[ -f "${scratch}/${tarball_name}" ]] || fail "npm pack did not produce the expected artifact: ${scratch}/${tarball_name}"

  place_or_skip_or_fail "${scratch}/${tarball_name}" "${local_feed}/${tarball_name}" "${name} ${version}" tgz_content_digest
  rm -rf "${scratch}"
}

main() {
  require_command dotnet
  # python3: needed only to compare .nupkg content across runs (nupkg_content_digest) -- a
  # .nupkg is a zip and whole-file byte comparison is not reliable for it, see the header
  # comment.
  require_command python3
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
