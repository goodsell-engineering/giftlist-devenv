#!/usr/bin/env bash
#
# Propagates the canonical Architecture/ test suite (giftlist-giftlists/tests/
# GiftLists.UnitTests/Architecture) to every other service repo's
# {Service}.UnitTests/Architecture folder, and
# regenerates each repo's architecture-tests.sha256 manifest so ArchitectureTestSyncTests can
# detect drift between them at test time.
#
# Some Architecture/ files are deliberately repo-specific and never copied anywhere else, not
# an oversight in the common_files list below:
#   - BuildingBlocks.UnitTests/Architecture/ErrorKindTransportMappingTests.cs — the ErrorKind
#     mapping table it names (GL-53) only makes sense where the table itself lives.
#   - Gateway.UnitTests/Architecture/GrpcStatusCodeCastTests.cs — pins a cast against Grpc.Core
#     (GL-18), which none of the other four repos may reference (CONVENTIONS.md "Project reference graph"); copying this
#     one into them would just fail to compile.
#   - Gateway.UnitTests/Architecture/ProjectionWriteBindingTests.cs — binds the CONVENTIONS.md "Messaging" blind-insert
#     detector to a named real file (GL-61). Gateway owns the only projection in the system, so
#     there is nothing for the other four repos to bind to; copied there it would assert nothing.
#
# ONE COUNTERPART THIS SCRIPT CANNOT SYNC, named here because nothing else would name it:
#   giftlist-web/citations.test.ts is the web half of CitationRuleTests.cs (GL-83). It cannot be copied —
#   different language, and since the GL-25 split a different repo — so it is hand-maintained.
#   What has to stay in step: the ban itself (the section sign never appears in source), and the
#   GENERATED_MARKERS / GeneratedMarkers list, duplicated verbatim in both and iterated by both
#   probes so a marker added to one and not the other is a visible diff.
#   What deliberately differs, and why: "is this file text?" is decided by a strict UTF-8 decode
#   in C# and by scanning the decoded string for U+FFFD in TypeScript (Node has no strict-decode
#   equivalent that is cheaper than this); and the skipped-directory lists differ because the
#   build output differs (bin/obj/.vs/.idea/TestResults for .NET, coverage for npm). Neither
#   difference changes which authored file is scanned.
#
# Since GL-25 this script lives in giftlist-devenv and writes into the *sibling clones*
# (ARCHITECTURE.md "Packaging: local feed" sketches that layout; clone-all.sh creates it), which
# is why it is here and not in one of the five repos it edits: no service repo can see the other
# four, and devenv is the only checkout that sees all of them. A missing sibling is a hard error
# rather than a skip — a silent skip is how one repo's copy drifts.
#
# Usage:
#   scripts/macos/sync-arch-tests.sh
#
# Edit the canonical copy in giftlist-giftlists, then run this script, then commit everything it
# touched IN EACH REPO IT TOUCHED — five commits and five pull requests, which is the multi-repo
# cost ARCHITECTURE.md "The cost of multi-repo" warns about, paid here rather than denied. Do not
# hand-edit any of the other four repos' Architecture/ folders directly — the next run of this
# script (or ArchitectureTestSyncTests, in CI) will just flag the drift.

# MACOS FORK of scripts/linux/sync-arch-tests.sh. Keep the two in step: a behaviour change made to one
# belongs in the other. Differences, all for BSD userland and the stock /bin/bash 3.2:
#   - sha256sum -> shasum -a 256   (ships with every macOS; sha256sum only on recent ones).

set -euo pipefail

# The directory holding all seven sibling clones: the parent of giftlist-devenv.
readonly workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly canonical_dir="${workspace}/giftlist-giftlists/tests/GiftLists.UnitTests/Architecture"
readonly target_dirs=(
  "${workspace}/giftlist-buildingblocks/tests/BuildingBlocks.UnitTests/Architecture"
  "${workspace}/giftlist-gateway/tests/Gateway.UnitTests/Architecture"
  "${workspace}/giftlist-identity/tests/Identity.UnitTests/Architecture"
  "${workspace}/giftlist-reservations/tests/Reservations.UnitTests/Architecture"
)

# The set of files that must be byte-identical across every repo. Everything else under a
# repo's Architecture/ folder (currently just BuildingBlocks' ErrorKindTransportMappingTests.cs)
# is repo-specific and is left alone by this script.
readonly common_files=(
  "DependencyRuleTests.cs"
  "ExceptionAssertionRuleTests.cs"
  "NamingConventionTests.cs"
  "TargetFrameworkTests.cs"
  "DeferredRuleTests.cs"
  "ProjectionWriteRuleTests.cs"
  "CitationRuleTests.cs"
  "InputPortInjectionRuleTests.cs"
  "SuiteLabelRuleTests.cs"
  "ArchitectureTestSyncTests.cs"
  "RepoRootFileSyncTests.cs"
  "Support/ProjectAssets.cs"
  "Support/ProjectFile.cs"
  "Support/ProjectRing.cs"
  "Support/ProjectionWriteProbe.cs"
  "Support/RepoDiscovery.cs"
  "Support/SourceFiles.cs"
)

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# Regenerates {dir}/architecture-tests.sha256 by hashing the *canonical* copy of every common
# file — so every repo's manifest, including the canonical one's own, always states what the
# canonical content's hash actually is, never what happens to already be on disk locally.
generate_manifest() {
  local dir="$1"
  local manifest="${dir}/architecture-tests.sha256"

  : > "${manifest}"
  for relative_file in "${common_files[@]}"; do
    printf '%s\t%s\n' "${relative_file}" "$(sha256_of "${canonical_dir}/${relative_file}")" >> "${manifest}"
  done
}

sync_target() {
  local target_dir="$1"

  mkdir -p "${target_dir}/Support"
  for relative_file in "${common_files[@]}"; do
    cp "${canonical_dir}/${relative_file}" "${target_dir}/${relative_file}"
  done
  generate_manifest "${target_dir}"

  echo "Synced ${target_dir#"${workspace}/"} (${#common_files[@]} files)."
}

main() {
  if [[ ! -d "${canonical_dir}" ]]; then
    echo "Canonical directory not found: ${canonical_dir}" >&2
    echo "Expected the seven repos cloned as siblings of giftlist-devenv; run clone-all.sh." >&2
    exit 1
  fi

  for target_dir in "${target_dirs[@]}"; do
    if [[ ! -d "$(dirname "$(dirname "$(dirname "${target_dir}")")")" ]]; then
      echo "Sibling clone missing for: ${target_dir}" >&2
      echo "Refusing to sync only some repos — that is how one copy drifts. Run clone-all.sh." >&2
      exit 1
    fi
  done

  # The canonical copy needs its own manifest too — ArchitectureTestSyncTests runs there as well.
  generate_manifest "${canonical_dir}"
  echo "Regenerated manifest for ${canonical_dir#"${workspace}/"} (canonical)."

  for target_dir in "${target_dirs[@]}"; do
    sync_target "${target_dir}"
  done
}

main "$@"
