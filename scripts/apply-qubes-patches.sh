#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clone a Qubes patches repository and a downstream repository, fetch the
upstream tag matching the version declared in the patches repository's version
file, apply all patches on top of that tag via git am, and force-push the
result branch to the downstream repository.

The patches repository must contain:
  - A version file whose sole content is the upstream version string.
  - Patch files in git format-patch (mbox) format, applied in lexicographic
    order.

Options:
  -h, --help                        Show this help message and exit
  -v, --verbose                     Enable verbose output (set -x).
                                    Note: token value will be visible in output.
      --patches-repo OWNER/REPO     Patches repository in OWNER/REPO form,
                                    e.g. QubesOS/qubes-grub2. (required)
      --downstream-repo OWNER/REPO  Downstream repository to push the result
                                    branch to, in OWNER/REPO form,
                                    e.g. trenchboot/grub. (required)
      --upstream-url URL            URL of the upstream repository to fetch
                                    the version tag from, e.g.
                                    https://git.savannah.gnu.org/git/grub.git.
                                    (required)
      --upstream-tag-prefix PREFIX  Prefix prepended to the version string to
                                    form the upstream tag name, e.g. "grub-"
                                    produces "grub-2.06" and "RELEASE-"
                                    produces "RELEASE-4.19.4". (required)
      --result-branch BRANCH        Name of the branch to create in the
                                    downstream repository and push the patched
                                    tree to, e.g. qubes-grub2-with-patches.
                                    (required)
      --token TOKEN                 GitHub personal access token with push
                                    access to the downstream repository.
                                    (required)

Exit codes:
  0   Branch pushed successfully
  1   Error

Example:
  $(basename "$0") \\
    --patches-repo        QubesOS/qubes-grub2 \\
    --downstream-repo     trenchboot/grub \\
    --upstream-url        https://git.savannah.gnu.org/git/grub.git \\
    --upstream-tag-prefix grub- \\
    --result-branch       qubes-grub2-with-patches \\
    --token               ghp_your_token
EOF
}

PATCHES_REPO=""
DOWNSTREAM_REPO=""
UPSTREAM_URL=""
UPSTREAM_TAG_PREFIX=""
RESULT_BRANCH=""
TOKEN=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--verbose)
                set -x
                shift
                ;;
            --patches-repo)
                PATCHES_REPO="$2"
                shift 2
                ;;
            --downstream-repo)
                DOWNSTREAM_REPO="$2"
                shift 2
                ;;
            --upstream-url)
                UPSTREAM_URL="$2"
                shift 2
                ;;
            --upstream-tag-prefix)
                UPSTREAM_TAG_PREFIX="$2"
                shift 2
                ;;
            --result-branch)
                RESULT_BRANCH="$2"
                shift 2
                ;;
            --token)
                TOKEN="$2"
                shift 2
                ;;
            -*)
                echo "ERROR: Unknown option '$1'" >&2
                usage >&2
                exit 1
                ;;
            *)
                echo "ERROR: Unexpected argument '$1'" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

# Validate required parameters:
errors=0
[[ -z "$PATCHES_REPO"        ]] && { echo "ERROR: --patches-repo is required."        >&2; errors=$((errors+1)); }
[[ -z "$DOWNSTREAM_REPO"     ]] && { echo "ERROR: --downstream-repo is required."     >&2; errors=$((errors+1)); }
[[ -z "$UPSTREAM_URL"        ]] && { echo "ERROR: --upstream-url is required."        >&2; errors=$((errors+1)); }
[[ -z "$UPSTREAM_TAG_PREFIX" ]] && { echo "ERROR: --upstream-tag-prefix is required." >&2; errors=$((errors+1)); }
[[ -z "$RESULT_BRANCH"       ]] && { echo "ERROR: --result-branch is required."       >&2; errors=$((errors+1)); }
[[ -z "$TOKEN"               ]] && { echo "ERROR: --token is required."               >&2; errors=$((errors+1)); }
if [[ $errors -gt 0 ]]; then
    usage >&2
    exit 1
fi

# Clone the patches repository:
echo "Cloning patches repository ${PATCHES_REPO}..."
git clone "https://github.com/${PATCHES_REPO}.git" patches-repo

# Read the upstream version from the patches repository's version file:
VERSION="$(tr -d '[:space:]' < patches-repo/version)"
UPSTREAM_TAG="${UPSTREAM_TAG_PREFIX}${VERSION}"
echo "Upstream version: ${VERSION}, tag: ${UPSTREAM_TAG}"

# Clone the downstream repository using the provided token:
echo "Cloning downstream repository ${DOWNSTREAM_REPO}..."
git clone "https://x-access-token:${TOKEN}@github.com/${DOWNSTREAM_REPO}.git" downstream-repo

cd downstream-repo

# Add the upstream remote and fetch only the required tag:
echo "Fetching upstream tag ${UPSTREAM_TAG} from ${UPSTREAM_URL}..."
git remote add upstream "$UPSTREAM_URL"
git fetch upstream "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"

# Configure the git identity used for the commits created by git am:
git config user.name  'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'

# Create the result branch at the upstream tag and apply the patches:
echo "Creating branch '${RESULT_BRANCH}' at tag '${UPSTREAM_TAG}'..."
git checkout -b "$RESULT_BRANCH" "$UPSTREAM_TAG"

echo "Applying patches from ${PATCHES_REPO}..."
git am ../patches-repo/*.patch

# Force-push the result branch to the downstream repository so that re-runs
# are idempotent:
echo "Pushing '${RESULT_BRANCH}' to ${DOWNSTREAM_REPO}..."
git push --force origin "$RESULT_BRANCH"

echo "Done. Branch '${RESULT_BRANCH}' pushed to ${DOWNSTREAM_REPO}."
