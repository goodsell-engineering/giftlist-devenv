#!/usr/bin/env bash
#
# Propagates the root-level build files that must be byte-identical in every .NET repo, from the
# canonical copy in giftlist-buildingblocks into the other four, and regenerates each repo's
# repo-root-files.sha256 manifest so RepoRootFileSyncTests can detect drift at test time.
#
# WHY THIS EXISTS. Before the GL-25 split there was one Directory.Build.props, at the monorepo
# root, and MSBuild's own directory walk gave every project in every service the same values: one
# file, no copies, nothing that could drift. MSBuild does not walk out of a repo, so the split
# ends that free ride and each .NET repo root needs its own copy. "Five identical files kept
# identical by hand" is exactly the drift CONVENTIONS.md "Target framework" exists to prevent,
# which is why the copies and the divergence check landed in the same change.
#
# WHICH REPOS, AND WHY NOT SEVEN. Five: the .NET repos. giftlist-web and giftlist-devenv contain
# no MSBuild project, so a Directory.Build.props in either would be a file nothing ever reads,
# and this script would then be policing a copy whose divergence could not break anything. When
# giftlist-web grows a shared root file of its own kind, it gets its own mechanism -- the two
# populations do not belong in one manifest.
#
# WHY THE CANONICAL COPY IS IN giftlist-buildingblocks AND NOT HERE. A template kept in devenv is
# a sixth copy that nothing builds against, so an error in it is invisible until it is
# propagated. giftlist-buildingblocks' copy is load-bearing -- its own five projects inherit it
# -- so a broken canonical file fails in the repo that owns it, first.
#
# WHAT THIS DOES NOT CHECK: that the canonical file is *correct*. Every repo can agree on a wrong
# file. TargetFrameworkTests.DirectoryBuildProps_ShouldMatchConventionsVerbatim is what pins the
# content against the block CONVENTIONS.md documents; this script and RepoRootFileSyncTests pin
# the copies against each other. Both halves are needed and neither subsumes the other.
#
# ADDING A FILE TO THE SET: append it to synced_files below and re-run. CONVENTIONS.md "Enforced
# mechanically" already names .editorconfig as the next one, governed by exactly this rule, when
# it is added -- it does not exist anywhere in the project yet, so it is deliberately not listed.
#
# Usage:
#   scripts/sync-repo-roots.sh
#
# Edit the canonical copy in giftlist-buildingblocks, run this, then commit everything it touched
# in each repo it touched. Do not hand-edit any other repo's copy: RepoRootFileSyncTests will
# just flag the drift on the next test run.

set -euo pipefail

# The directory holding all seven sibling clones: the parent of giftlist-devenv.
readonly workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly canonical_repo="${workspace}/giftlist-buildingblocks"
readonly target_repos=(
  "${workspace}/giftlist-gateway"
  "${workspace}/giftlist-identity"
  "${workspace}/giftlist-giftlists"
  "${workspace}/giftlist-reservations"
)

readonly synced_files=(
  "Directory.Build.props"
  # GL-26: five byte-identical nuget.config files, each binding the GiftList package ids to the
  # local feed exclusively via packageSourceMapping. Unsynced, a silently drifted copy in one
  # repo (a dropped mapping entry, say) resolves those ids from nuget.org instead and nothing
  # fails loudly -- exactly the dependency-confusion gap GL-26 exists to close.
  "nuget.config"
)

readonly manifest_name="repo-root-files.sha256"

sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# Regenerates {repo}/repo-root-files.sha256 by hashing the *canonical* copy of every synced file
# -- so every repo's manifest, the canonical repo's own included, always states what the
# canonical content's hash actually is, never what happens to be on disk locally.
generate_manifest() {
  local repo="$1"
  local manifest="${repo}/${manifest_name}"

  : > "${manifest}"
  for relative_file in "${synced_files[@]}"; do
    printf '%s\t%s\n' "${relative_file}" "$(sha256_of "${canonical_repo}/${relative_file}")" >> "${manifest}"
  done
}

main() {
  if [[ ! -d "${canonical_repo}" ]]; then
    echo "Canonical repo not found: ${canonical_repo}" >&2
    echo "Expected the seven repos cloned as siblings of giftlist-devenv; run clone-all.sh." >&2
    exit 1
  fi

  for relative_file in "${synced_files[@]}"; do
    if [[ ! -f "${canonical_repo}/${relative_file}" ]]; then
      echo "Canonical file not found: ${canonical_repo}/${relative_file}" >&2
      exit 1
    fi
  done

  for repo in "${target_repos[@]}"; do
    if [[ ! -d "${repo}" ]]; then
      echo "Sibling clone missing: ${repo}" >&2
      echo "Refusing to sync only some repos -- that is how one copy drifts. Run clone-all.sh." >&2
      exit 1
    fi
  done

  generate_manifest "${canonical_repo}"
  echo "Regenerated manifest for ${canonical_repo#"${workspace}/"} (canonical)."

  for repo in "${target_repos[@]}"; do
    for relative_file in "${synced_files[@]}"; do
      cp "${canonical_repo}/${relative_file}" "${repo}/${relative_file}"
    done
    generate_manifest "${repo}"
    echo "Synced ${repo#"${workspace}/"} (${#synced_files[@]} files)."
  done
}

main "$@"
