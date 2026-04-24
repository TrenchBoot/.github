#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

# Synthesize a rebase base for QubesOS-derivative TrenchBoot source repos.
#
# Given a TrenchBoot source repo (e.g. TrenchBoot/xen) and a QubesOS packaging
# repo (e.g. QubesOS/qubes-vmm-xen), produce a branch in the source repo whose
# HEAD is:
#
#   [upstream tag at <version>] + [one commit applying qubes patches]
#
# This branch is suitable as the "upstream" input to rebase.sh: rebasing the
# TrenchBoot downstream branch onto it surfaces any conflict between TrenchBoot
# changes and qubes patches.
#
# Packaging files (spec, .qubesbuilder, version, rel, RPM sources) are NOT
# committed into the source repo here. They are merged at build time by
# overlay-packaging.sh. This keeps the source repo's git history free of
# packaging churn and makes xen/grub prep logic identical modulo parameters.
#
# Runs the same on a developer laptop and in CI.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required options:
  --work-dir DIR            Directory to clone into (created if missing).
                            Will contain <work-dir>/pkg and <work-dir>/src.
  --source-repo URL         TrenchBoot source repo URL
                            (e.g. https://github.com/TrenchBoot/xen.git).
  --pkg-repo URL            QubesOS packaging repo URL
                            (e.g. https://github.com/QubesOS/qubes-vmm-xen.git).
  --upstream-url URL        Upstream source repo URL
                            (e.g. https://xenbits.xenproject.org/git-http/xen.git).
  --upstream-tag-format FMT Format string for the upstream tag, with a single
                            '%s' placeholder for the version read from
                            pkg/version (e.g. "RELEASE-%s" or "grub-%s").
  --spec-in NAME            Spec-in filename inside the packaging repo, used to
                            discover patch list (e.g. "xen.spec.in").
  --prep-branch NAME        Name of the branch to create in the source repo
                            (e.g. "qubes-vmm-xen-with-patches-rebase-prep").

Optional:
  --push                    Push the synthesized branch to source-repo origin
                            (force-push; the branch is owned by this script).
  --source-token TOKEN      Token for HTTPS auth when cloning/pushing.
                            If omitted, existing git credentials are used.
  --commit-user-name NAME   Default: github-actions[bot].
  --commit-user-email EMAIL Default: github-actions[bot]@users.noreply.github.com.
  --commit-date TIMESTAMP   GIT_{AUTHOR,COMMITTER}_DATE. Default
                            2024-01-01T00:00:00. Must stay stable across runs
                            so that rebase.sh detects "no new rebase needed"
                            when inputs are unchanged.
  -h, --help                Print this help.

On success:
  <work-dir>/pkg          is a clone of the QubesOS packaging repo; read the
                          upstream version from <work-dir>/pkg/version.
  <work-dir>/src          is a clone of the source repo with <prep-branch>
                          checked out, HEAD = upstream_tag + qubes-patches.
  If --push was given, the prep branch is pushed to the source repo.

Exit codes:
  0   success
  1   argument or configuration error
  2   a qubes patch failed to apply on top of the upstream tag
EOF
}

WORK_DIR=""
SOURCE_REPO=""
PKG_REPO=""
UPSTREAM_URL=""
TAG_FORMAT=""
SPEC_IN=""
PREP_BRANCH=""
PUSH=""
SOURCE_TOKEN=""
COMMIT_USER_NAME="github-actions[bot]"
COMMIT_USER_EMAIL="github-actions[bot]@users.noreply.github.com"
COMMIT_DATE="2024-01-01T00:00:00"

while [[ $# -gt 0 ]]; do
    case $1 in
        --work-dir)            WORK_DIR="$2"; shift 2 ;;
        --source-repo)         SOURCE_REPO="$2"; shift 2 ;;
        --pkg-repo)            PKG_REPO="$2"; shift 2 ;;
        --upstream-url)        UPSTREAM_URL="$2"; shift 2 ;;
        --upstream-tag-format) TAG_FORMAT="$2"; shift 2 ;;
        --spec-in)             SPEC_IN="$2"; shift 2 ;;
        --prep-branch)         PREP_BRANCH="$2"; shift 2 ;;
        --push)                PUSH="true"; shift ;;
        --source-token)        SOURCE_TOKEN="$2"; shift 2 ;;
        --commit-user-name)    COMMIT_USER_NAME="$2"; shift 2 ;;
        --commit-user-email)   COMMIT_USER_EMAIL="$2"; shift 2 ;;
        --commit-date)         COMMIT_DATE="$2"; shift 2 ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

missing=0
for var in WORK_DIR SOURCE_REPO PKG_REPO UPSTREAM_URL TAG_FORMAT SPEC_IN PREP_BRANCH; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --${var,,} (converted: --${var//_/-}) is required" >&2
        missing=1
    fi
done
if [[ $missing -ne 0 ]]; then
    usage >&2
    exit 1
fi

tokenize_url() {
    local url="$1" token="$2"
    if [[ -z "$token" ]]; then
        echo "$url"
        return
    fi
    # https://host/... -> https://<token>@host/...
    echo "$url" | sed -E "s|^https://([^@/]+)|https://${token}@\1|"
}

mkdir -p "$WORK_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

echo "[prep] Cloning packaging repo $PKG_REPO into $WORK_DIR/pkg..."
rm -rf "$WORK_DIR/pkg"
git clone --depth 1 "$PKG_REPO" "$WORK_DIR/pkg"

VERSION=$(cat "$WORK_DIR/pkg/version")
UPSTREAM_TAG="${TAG_FORMAT//%s/$VERSION}"
echo "[prep] Upstream version : $VERSION"
echo "[prep] Upstream tag     : $UPSTREAM_TAG"

echo "[prep] Cloning source repo $SOURCE_REPO into $WORK_DIR/src..."
rm -rf "$WORK_DIR/src"
git clone "$(tokenize_url "$SOURCE_REPO" "$SOURCE_TOKEN")" "$WORK_DIR/src"

cd "$WORK_DIR/src"

echo "[prep] Fetching upstream tag $UPSTREAM_TAG..."
if git remote get-url upstream &>/dev/null; then
    git remote set-url upstream "$UPSTREAM_URL"
else
    git remote add upstream "$UPSTREAM_URL"
fi
git fetch upstream "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"

echo "[prep] Creating prep branch '$PREP_BRANCH' at $UPSTREAM_TAG..."
git checkout --detach "$UPSTREAM_TAG"
git branch -D "$PREP_BRANCH" 2>/dev/null || true
git checkout -b "$PREP_BRANCH"

echo "[prep] Discovering patch list from pkg/$SPEC_IN..."
mapfile -t PATCHES < <(grep -E '^Patch[0-9]+:' "$WORK_DIR/pkg/$SPEC_IN" | awk '{print $2}')
if [[ ${#PATCHES[@]} -eq 0 ]]; then
    echo "[prep] WARNING: no Patch: lines found in $SPEC_IN" >&2
fi

echo "[prep] Applying ${#PATCHES[@]} patches..."
for patch_file in "${PATCHES[@]}"; do
    echo "[prep]   $patch_file"
    if ! git apply "$WORK_DIR/pkg/$patch_file"; then
        echo "ERROR: failed to apply $patch_file onto $UPSTREAM_TAG" >&2
        exit 2
    fi
done

echo "[prep] Staging and committing..."
git add -A
GIT_AUTHOR_NAME="$COMMIT_USER_NAME" \
GIT_AUTHOR_EMAIL="$COMMIT_USER_EMAIL" \
GIT_AUTHOR_DATE="$COMMIT_DATE" \
GIT_COMMITTER_NAME="$COMMIT_USER_NAME" \
GIT_COMMITTER_EMAIL="$COMMIT_USER_EMAIL" \
GIT_COMMITTER_DATE="$COMMIT_DATE" \
git commit --no-gpg-sign -m "QubesOS patches applied on top of $UPSTREAM_TAG"

if [[ "$PUSH" == "true" ]]; then
    echo "[prep] Pushing $PREP_BRANCH to origin (force)..."
    if [[ -n "$SOURCE_TOKEN" ]]; then
        push_url="$(tokenize_url "$SOURCE_REPO" "$SOURCE_TOKEN")"
        git push --force "$push_url" "$PREP_BRANCH"
    else
        git push --force origin "$PREP_BRANCH"
    fi
fi

echo "[prep] Done."
echo "[prep] work-dir  : $WORK_DIR"
echo "[prep] pkg dir   : $WORK_DIR/pkg"
echo "[prep] src dir   : $WORK_DIR/src"
echo "[prep] version   : $VERSION"
echo "[prep] prep HEAD : $(git rev-parse HEAD)"
