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
#   - a pre-GL-100 build-stamp mismatch -> re-verify and migrate. See "THE ONE-TIME MIGRATION"
#     below -- this is not the common case and not a way around the guard.
#   - DIFFERENT content, genuinely      -> fail hard, exactly as before. The feed is left
#     untouched -- the scratch artifact is discarded, never moved over the existing file. This is
#     the one case the guard exists for at all (a forgotten version bump), and GL-100 does not
#     weaken it: it only stops the guard firing on packages nobody touched.
#
# WHAT "SAME CONTENT" MEANS, AND WHY IT'S TWO DIFFERENT CHECKS. A .nupkg and a .tgz are both
# zip-family archives, and naive whole-file byte comparison ("just sha256sum the two files") was
# tried against this workspace's own packages before picking the approach below:
#   - .tgz (npm pack): whole-file sha256 IS stable across runs of identical source -- verified by
#     packing @giftlist/gateway-client twice in a row with nothing changed and diffing the
#     tarballs byte-for-byte identical, matching npm's own printed `shasum`/`integrity` lines.
#     npm normalises tar entry metadata for exactly this reason. So the .tgz check is plain
#     whole-file byte identity; see place_tgz_or_skip_or_fail.
#   - .nupkg (dotnet pack): whole-file sha256 is NOT stable, for reasons found by repeatedly
#     packing the SAME BuildingBlocks source and diffing the results rather than assumed:
#       1. The NuGet/OPC packer regenerates two container-bookkeeping entries with a fresh random
#          identifier on every single pack, unconditionally, regardless of content: the metadata
#          part `package/services/metadata/core-properties/*.psmdcp` (the GUID-shaped filename
#          itself changes every run, even though the file's own contents don't) and `_rels/.rels`
#          (which both references that filename and carries its own randomly-generated
#          relationship id for it). Neither carries information a consumer's build could ever
#          observe. Excluded from the digest entirely -- see nupkg_tool.py's `load_normalized_entries`,
#          written to a scratch file by write_nupkg_tool and invoked by nupkg_compare below.
#       2. The .NET SDK's default SourceLink-style behaviour embeds `git rev-parse HEAD` for the
#          WHOLE containing repo into both the .nuspec (`<repository commit="...">`) and the
#          compiled assembly's AssemblyInformationalVersion (a "+<40 hex chars>" suffix). That
#          commit describes "what commit was HEAD when this was built", not "what this package's
#          own source is": a commit to a completely unrelated file anywhere else in the repo
#          moves it just as much as a change to this package would. `dotnet pack` below is given
#          `-p:EnableSourceControlManagerQueries=false`, which stops the SDK querying git at all,
#          so a fresh pack's .nuspec and .dll depend only on this package's own source. Kept even
#          though it introduces the one-time migration cost below, because the alternative --
#          leaving it on -- reintroduces exactly the "a repeat run refuses" failure GL-100 exists
#          to fix, just relocated one level down: EVERY subsequent commit to the repo, touching
#          this package or not, would make an unrelated future `make pack-all` disagree with
#          whatever got packed today.
#       3. Independently of both of the above, and NOT fixable by any pack-time flag: a .NET
#          assembly's Module Version ID (MVID, in the `#GUID` metadata heap), its PE COFF header
#          timestamp, and its PDB CodeView debug-directory GUID+hash are regenerated on every
#          single compile, by design -- deterministic only for a genuinely identical compiler
#          invocation, not guaranteed to reproduce across separate pack *sessions* (a different
#          SDK patch, a different machine, a different day). Verified, not assumed: forcing two
#          `dotnet pack` runs of the exact same BuildingBlocks source at the exact same declared
#          git commit still produced 72 differing bytes, every one of them inside these specific
#          fields (confirmed by walking the actual PE/CLI structures, not guessed from offsets);
#          every byte that is actual content -- IL, metadata tables, string/blob heaps -- matched.
#          These fields are zeroed out before hashing; see nupkg_tool.py's `normalize_dll`.
#     Once all three are accounted for, every remaining entry in the .nupkg is byte-identical
#     across repeated packs of the same source, at the same declared commit. This asymmetry
#     between the two artifact kinds is deliberate, not an oversight: dotnet pack and npm pack
#     just don't offer the same reproducibility guarantee out of the box.
#
# THE ONE-TIME MIGRATION. Point 2 above has a consequence for a feed that already has packages in
# it from before this fix landed: THEIR .nuspec/.dll still carry whatever commit was HEAD when
# THEY were packed. A fresh pack of the exact same, still-unchanged source no longer embeds any
# commit at all, so the two will not compare equal even after every normalisation above -- not
# because content changed, but because the very definition of "content" (what gets embedded)
# changed under this fix. Silently trusting that and overwriting would be exactly the kind of
# guard-widening this script must never do, so it is not trusted -- it is RE-VERIFIED: when an
# existing feed artifact's .nuspec still has a `<repository commit="...">` element, this script
# rebuilds the SAME current source with that EXACT commit forced back in
# (`-p:SourceRevisionId=<that commit>`) and compares THAT, not the fresh pack, against the feed.
# Only if THAT comparison also says "same" does it conclude the underlying source is genuinely
# unchanged and replace the feed's copy with the fresh (unstamped) pack, logging it as "migrated"
# -- a third, distinct outcome from both "packed" and "skipped". If it says "different", this is
# a real conflict and fails exactly like any other mismatch. This is not the "delete the file to
# get around the guard" shortcut the giftlist-contract-change skill forbids: that shortcut trusts
# an unreviewed claim that a mismatch doesn't matter; this recomputes the exact same
# already-proven comparison against a like-for-like rebuild before ever accepting one, and only
# ever fires for a feed artifact carrying the specific, checkable marker of predating this fix --
# once a package has gone through it, the marker is gone and this path never triggers for it
# again. See nupkg_compare / nupkg_legacy_commit and the legacy branch in pack_dotnet_package.
#
# RECOVERING FROM A GENUINE, NOT-YOUR-FAULT FAILURE. Normalisation above cannot absorb a PE
# *layout* shift, only fixed-size build-identity fields: a CodeView blob's bytes are zeroed but
# its own LENGTH is not, so a workspace at a different absolute path -- a different clone
# location, a rename, even a path a couple of characters shorter -- embeds a differently-sized
# PDB path string, which shifts every downstream offset (confirmed: running this script from a
# workspace path two characters shorter than the one an artifact was packed from fails hard on
# BuildingBlocks 0.1.0, reproducing GL-100's exact symptom). The same can happen from an SDK
# patch bump. When it does, the migration path above has already consumed its one legitimate
# use for that artifact, so the guard correctly refuses -- on a package nobody touched, with no
# `--force` by design. The recovery: **clearing local-feed/ and re-running `make pack-all` is
# safe and correct, not a workaround.** The feed is generated, uncommitted, and specific to this
# one workspace; every consumer restored FROM it into its own NuGet/npm cache
# (`~/.nuget/packages`, npm's own cache), which keeps its own copy regardless of what
# local-feed/ still contains. This is NOT the same act as the "delete one artifact to dodge a
# forgotten version bump" shortcut this file forbids elsewhere: that shortcut discards the one
# signal that a specific package's content silently changed at an existing version, reviewed by
# nobody. Clearing the whole feed discards nothing -- everything in it is about to be
# regenerated, reproducibly, from the same source that already is the source of truth. That
# distinction is the entire reason the guard is allowed to have this one exception.
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
#   scripts/linux/pack-all.sh

set -euo pipefail

# The directory holding all seven sibling clones: the parent of giftlist-devenv.
readonly workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# All scratch state for this run (nupkg_tool.py, and every pack_dotnet_package/pack_npm_client
# scratch dir) lives under one directory -- see main(). Two reasons, not one: (1) it puts every
# `mv` into local-feed/ on the SAME filesystem as the feed itself, so placing a finished
# artifact is an atomic rename rather than a cross-device copy; (2) a single EXIT trap below
# removes the whole thing on every exit path -- success, `fail`'s `exit 1`, or an interrupt --
# so an early failure (say, `dotnet pack` not producing the file its own output claimed to
# create) can never leave an orphaned temp dir behind just because that code path predates the
# happy path's own cleanup.
scratch_root=""
nupkg_tool=""
cleanup() {
  [[ -n "${scratch_root}" && -d "${scratch_root}" ]] && rm -rf "${scratch_root}"
}
trap cleanup EXIT

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
Run scripts/linux/clone-all.sh first (see README.md \"The sibling-clone layout\")."
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

# Writes nupkg_tool.py to a scratch file once per run (rather than re-embedding it in a heredoc
# on every one of the ~12 calls this script makes into it) and records the path in $nupkg_tool.
# See the header comment ("WHAT 'SAME CONTENT' MEANS" and "THE ONE-TIME MIGRATION") for what it
# does and why. python3 is assumed present on the host alongside dotnet/npm/node -- see
# README.md "Packing prerequisites".
write_nupkg_tool() {
  nupkg_tool="$(mktemp -p "${scratch_root}")"
  cat > "${nupkg_tool}" <<'PY'
import hashlib, re, sys, zipfile, struct

OPC_RELS = "_rels/.rels"
PSMDCP_RE = re.compile(r"^package/services/metadata/core-properties/.*\.psmdcp$")
REPOSITORY_LINE_RE = re.compile(r'[ \t]*<repository\b[^>]*/>\r?\n?')
REPOSITORY_COMMIT_RE = re.compile(rb'<repository\b[^>]*\bcommit="([0-9a-f]{40})"')

# IMAGE_DEBUG_DIRECTORY entry types whose BLOB is pure build-identity, safe to zero: CodeView
# (2, PDB GUID+age+path), Reproducible (16, a marker carrying no data of its own) and
# PdbChecksum (19, a content hash of the PDB). Deliberately NOT every type: type 17, Embedded
# Portable PDB, has its blob BE an actual copy of the PDB -- zeroing it would hide a real
# content change. Confirmed, not assumed: built with -p:DebugType=embedded (unused today --
# nothing in this workspace sets it) and a two-line source edit produced a 7,905-byte delta
# this comparer called "same" before this fix. Any type not in this set, known or not, is left
# untouched, so it still differs and the comparison still fails toward "different" -- the one
# direction this guard is allowed to be wrong in.
DEBUG_BLOB_TYPES_SAFE_TO_ZERO = {2, 16, 19}

def normalize_dll(data):
    """
    Zeroes the handful of fields a .NET PE/CLI assembly carries purely to identify THIS
    specific build -- never content a consumer's own build could observe -- so that two
    packs of identical source compare equal regardless of which machine, session or SDK
    patch produced them. Verified necessary, not assumed: forcing two `dotnet pack` runs of
    the exact same BuildingBlocks source (same commit, same declared version) still produced
    72 differing bytes, all five of them inside these exact fields; every other byte -- the
    IL, the metadata tables, the string/blob heaps that hold real content -- matched.
    Located by walking the real PE/CLI structures (COFF header, optional header data
    directories, section table, CLR header, metadata root, stream headers), not by
    hardcoding offsets, so this holds even if a future package's layout shifts.
    """
    data = bytearray(data)
    if data[0:2] != b"MZ" or len(data) < 0x40:
        return bytes(data)  # not a PE; nothing to normalise
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if e_lfanew + 4 > len(data) or data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return bytes(data)
    coff_off = e_lfanew + 4
    _machine, num_sections, _timestamp = struct.unpack_from("<HHI", data, coff_off)
    # COFF header TimeDateStamp: deterministic builds replace this with a content-derived
    # value, so it moves whenever anything else here does -- zero it rather than trust it.
    struct.pack_into("<I", data, coff_off + 4, 0)
    size_of_opt_header = struct.unpack_from("<H", data, coff_off + 16)[0]
    opt_off = coff_off + 20
    if size_of_opt_header == 0:
        return bytes(data)
    magic = struct.unpack_from("<H", data, opt_off)[0]
    is_pe32plus = magic == 0x20B
    # PE checksum: usually left 0 by `dotnet build`, zeroed defensively anyway.
    struct.pack_into("<I", data, opt_off + 0x40, 0)
    data_dir_off = opt_off + (112 if is_pe32plus else 96)
    debug_rva, debug_size = struct.unpack_from("<II", data, data_dir_off + 6 * 8)
    clr_rva, clr_size = struct.unpack_from("<II", data, data_dir_off + 14 * 8)

    sec_off = opt_off + size_of_opt_header
    sections = []
    for i in range(num_sections):
        _name, vsize, vaddr, rawsize, rawptr = struct.unpack_from("<8sIIII", data, sec_off + i * 40)
        sections.append((vsize, vaddr, rawsize, rawptr))

    def rva_to_off(rva):
        if rva == 0:
            return None
        for vsize, vaddr, rawsize, rawptr in sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                return rawptr + (rva - vaddr)
        return None

    if debug_size:
        debug_file_off = rva_to_off(debug_rva)
        if debug_file_off is not None:
            for i in range(debug_size // 28):
                eoff = debug_file_off + i * 28
                (_chars, _ts, _maj, _minr, typ, sizeofdata, _addrofraw,
                 ptrtorawdata) = struct.unpack_from("<IIHHIIII", data, eoff)
                # Each IMAGE_DEBUG_DIRECTORY entry's own TimeDateStamp -- always a build
                # timestamp per the PE spec, regardless of entry type.
                struct.pack_into("<I", data, eoff + 4, 0)
                # The blob itself: only for the types known to be pure build-identity -- see
                # DEBUG_BLOB_TYPES_SAFE_TO_ZERO above for which types and why.
                if typ in DEBUG_BLOB_TYPES_SAFE_TO_ZERO and sizeofdata and ptrtorawdata:
                    for j in range(sizeofdata):
                        data[ptrtorawdata + j] = 0

    if clr_size:
        clr_file_off = rva_to_off(clr_rva)
        if clr_file_off is not None:
            _cb, _majrt, _minrt, meta_rva, _meta_size = struct.unpack_from("<IHHII", data, clr_file_off)
            meta_off = rva_to_off(meta_rva)
            if meta_off is not None and data[meta_off:meta_off + 4] == b"BSJB":
                _maj, _minr, _reserved, length = struct.unpack_from("<HHII", data, meta_off + 4)
                p = meta_off + 16 + length
                _flags, nstreams = struct.unpack_from("<HH", data, p)
                p += 4
                for _ in range(nstreams):
                    stream_off, stream_size = struct.unpack_from("<II", data, p)
                    p += 8
                    name_start = p
                    end = data.index(b"\0", name_start)
                    name = bytes(data[name_start:end]).decode()
                    padded = ((end - name_start + 1) + 3) // 4 * 4
                    p = name_start + padded
                    if name == "#GUID":
                        # The Module Version ID (MVID) -- regenerated every compile by design,
                        # deterministic only for a fixed compiler version and fixed inputs
                        # (which the informational-version suffix used to be, see the legacy
                        # path below), never something a consumer's build depends on.
                        for j in range(stream_size):
                            data[meta_off + stream_off + j] = 0
    return bytes(data)

def strip_repository_element(nuspec_bytes):
    """Pre-GL-100 packs embed <repository type="git" commit="..."/>; packs built with
    -p:EnableSourceControlManagerQueries=false never do. Strip the element either way so a
    legacy artifact and a fresh one compare on everything else."""
    text = nuspec_bytes.decode("utf-8")
    text = REPOSITORY_LINE_RE.sub("", text)
    return text.encode("utf-8")

def load_normalized_entries(path):
    entries = {}
    with zipfile.ZipFile(path) as zf:
        for name in sorted(zf.namelist()):
            if name == OPC_RELS or PSMDCP_RE.match(name):
                continue
            data = zf.read(name)
            if name.endswith(".nuspec"):
                data = strip_repository_element(data)
            elif name.endswith(".dll"):
                data = normalize_dll(data)
            entries[name] = data
    return entries

def digest_of(entries):
    d = hashlib.sha256()
    for name in sorted(entries):
        d.update(name.encode("utf-8"))
        d.update(b"\0")
        d.update(hashlib.sha256(entries[name]).digest())
    return d.hexdigest()

def raw_nuspec_bytes(path):
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            if name.endswith(".nuspec"):
                return zf.read(name)
    return None

def main():
    mode = sys.argv[1]
    if mode == "compare":
        a, b = sys.argv[2], sys.argv[3]
        same = digest_of(load_normalized_entries(a)) == digest_of(load_normalized_entries(b))
        print("same" if same else "different")
    elif mode == "legacy-commit":
        raw = raw_nuspec_bytes(sys.argv[2])
        match = REPOSITORY_COMMIT_RE.search(raw) if raw else None
        print(match.group(1).decode("ascii") if match else "")
    else:
        print(f"nupkg_tool.py: unknown mode {mode!r}", file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()
PY
}

# "same" or "different" -- see the header comment for what this normalises away and why.
nupkg_compare() {
  python3 "${nupkg_tool}" compare "$1" "$2"
}

# The git commit a feed artifact's .nuspec still has embedded, if it predates GL-100 -- empty
# for anything packed by this version of the script. See "THE ONE-TIME MIGRATION" above.
nupkg_legacy_commit() {
  python3 "${nupkg_tool}" legacy-commit "$1"
}

# Feed placement for the npm .tgz -- the simple two-way case. See the header comment
# ("WHAT 'SAME CONTENT' MEANS"): whole-file byte identity is reliable for npm pack output, so
# there is no legacy-migration tier here, unlike pack_dotnet_package below.
place_tgz_or_skip_or_fail() {
  local scratch_artifact="$1" feed_path="$2" description="$3"

  if [[ ! -f "${feed_path}" ]]; then
    mv "${scratch_artifact}" "${feed_path}"
    echo "  ${description}: packed"
    return 0
  fi

  if [[ "$(sha256sum "${scratch_artifact}" | cut -d' ' -f1)" == "$(sha256sum "${feed_path}" | cut -d' ' -f1)" ]]; then
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
  local feed_path="${local_feed}/${filename}"
  local scratch
  scratch="$(mktemp -d -p "${scratch_root}")"

  echo "Packing ${package_id} ${version} (${relative_csproj})..."
  # -nodeReuse:false -p:UseSharedCompilation=false -m:1: several agents/services build
  # concurrently on a memory-constrained box; a lingering MSBuild worker node or the shared
  # compiler server is exactly the kind of background process that turns a tight box into an
  # "Internal CLR error".
  # -p:EnableSourceControlManagerQueries=false: stops the SDK embedding `git rev-parse HEAD` into
  # the .nuspec and the compiled assembly -- see the header comment ("WHAT 'SAME CONTENT' MEANS",
  # point 2). Without it, the artifact this produces would depend on which commit the repo
  # happens to be at right now, not just on this package's own source.
  # Packed into a scratch dir, not straight into the feed -- placement is decided below.
  dotnet pack "${csproj}" \
    --configuration Release \
    --output "${scratch}" \
    --verbosity minimal \
    -nodeReuse:false \
    -p:UseSharedCompilation=false \
    -p:EnableSourceControlManagerQueries=false \
    -m:1

  [[ -f "${scratch}/${filename}" ]] || fail "dotnet pack did not produce the expected artifact: ${scratch}/${filename}"

  if [[ ! -f "${feed_path}" ]]; then
    mv "${scratch}/${filename}" "${feed_path}"
    echo "  ${package_id} ${version}: packed"
    rm -rf "${scratch}"
    return 0
  fi

  local verdict
  verdict="$(nupkg_compare "${scratch}/${filename}" "${feed_path}")"

  if [[ "${verdict}" == "same" ]]; then
    rm -rf "${scratch}"
    echo "  ${package_id} ${version}: unchanged, already in the feed -- skipping"
    return 0
  fi

  # Not identical -- before failing, check whether the feed's copy predates GL-100 (see the
  # header comment, "THE ONE-TIME MIGRATION"). Re-verify by rebuilding THIS source with that
  # exact commit forced back in, rather than trusting the marker's mere presence.
  local legacy_commit
  legacy_commit="$(nupkg_legacy_commit "${feed_path}")"

  if [[ -n "${legacy_commit}" ]]; then
    local legacy_scratch legacy_pack_output
    legacy_scratch="$(mktemp -d -p "${scratch_root}")"
    if ! legacy_pack_output="$(dotnet pack "${csproj}" \
      --configuration Release \
      --output "${legacy_scratch}" \
      --verbosity minimal \
      -nodeReuse:false \
      -p:UseSharedCompilation=false \
      -p:SourceRevisionId="${legacy_commit}" \
      -m:1 2>&1)"; then
      fail "re-pack of ${package_id} ${version} at its feed-recorded commit ${legacy_commit:0:12} failed
(while re-verifying a pre-GL-100 artifact -- see \"THE ONE-TIME MIGRATION\"):
${legacy_pack_output}"
    fi

    if [[ -f "${legacy_scratch}/${filename}" ]] \
      && [[ "$(nupkg_compare "${legacy_scratch}/${filename}" "${feed_path}")" == "same" ]]; then
      rm -rf "${legacy_scratch}"
      mv -f "${scratch}/${filename}" "${feed_path}"
      echo "  ${package_id} ${version}: migrated (pre-GL-100 build stamp only -- re-verified" \
        "unchanged by re-embedding the feed's own recorded commit ${legacy_commit:0:12} and re-comparing)"
      rm -rf "${scratch}"
      return 0
    fi
    rm -rf "${legacy_scratch}"
  fi

  rm -rf "${scratch}"
  fail "${package_id} ${version} already exists in the feed with DIFFERENT content: ${feed_path}
NuGet/npm cache by (id, version); repacking the same version with different content would
silently leave every consumer that has already restored it on stale content. Bump the version
and try again -- do not delete this file to get around the guard (giftlist-contract-change
skill, ARCHITECTURE.md \"What 'breaking' means for a message contract\")."
}

pack_npm_client() {
  local client_dir="${workspace}/${npm_client_dir}"
  local package_json="${client_dir}/package.json"

  [[ -f "${package_json}" ]] || fail "expected package.json not found: ${package_json}"

  local name version tarball_name
  name="$(node -p "require('${package_json}').name")"
  version="$(node -p "require('${package_json}').version")"
  # npm's own tarball-naming rule: strip a leading "@scope/" slash by turning it into a dash, and
  # drop the "@". Matches what `npm pack` actually writes -- verified against the file already in
  # local-feed (giftlist-gateway-client-0.1.0.tgz) for @giftlist/gateway-client.
  tarball_name="$(echo "${name}" | sed -E 's#^@##; s#/#-#')-${version}.tgz"

  local scratch
  scratch="$(mktemp -d -p "${scratch_root}")"

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
    # straight into the feed -- see place_tgz_or_skip_or_fail, which decides whether it belongs
    # there.
    npm pack --pack-destination "${scratch}"
  )

  [[ -f "${scratch}/${tarball_name}" ]] || fail "npm pack did not produce the expected artifact: ${scratch}/${tarball_name}"

  place_tgz_or_skip_or_fail "${scratch}/${tarball_name}" "${local_feed}/${tarball_name}" "${name} ${version}"
  rm -rf "${scratch}"
}

main() {
  require_command dotnet
  # python3: needed only to compare .nupkg content across runs (nupkg_tool.py) -- a .nupkg is a
  # zip and whole-file byte comparison is not reliable for it, see the header comment.
  require_command python3
  # npm/node: checked here, not inside pack_npm_client, so a host missing either fails in under
  # a second -- before any of the six .NET packs run, not after ~70s of work already written to
  # the feed (GL-101: this is squarely what "make pack-all needs Node too" means in practice).
  require_command npm
  require_command node
  check_siblings_present
  mkdir -p "${local_feed}"
  # All scratch state for this run lives under one directory -- see the comment on
  # `scratch_root`/`cleanup` above.
  scratch_root="$(mktemp -d -p "${workspace}")"
  write_nupkg_tool

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
