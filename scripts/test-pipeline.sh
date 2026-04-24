#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

# Local test driver for the rebase/build pipeline. Exercises
# prep-qubes-rebase.sh, rebase.sh --local, and overlay-packaging.sh against
# real TrenchBoot and QubesOS repos. No network side-effects (no push, no PR).
#
# Usage:
#   test-pipeline.sh <repo> [stage]
#
# See --help for details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <repo> [stage]

Exercise the rebase/build pipeline locally for a TrenchBoot QubesOS-derivative
repo. All work stays in a work directory; no branches are pushed or PRs opened.

Repos:
  xen     Rebase TrenchBoot/xen:aem-next onto xen+qubes-vmm-xen patches.
  grub    Rebase TrenchBoot/grub:tb-dev onto grub+qubes-grub2 patches.

Stages:
  all       (default) prep + rebase + overlay in sequence. Continues past a
            rebase conflict so overlay can still be exercised.
  prep      Synthesize the rebase base (clone source+packaging, fetch upstream
            tag, apply qubes patches, commit).
  rebase    Run rebase.sh --local on the prep work-dir. Exits 2 on conflict;
            creates a local conflict branch with instructions.
  overlay   Snapshot the source tree, merge packaging onto it, verify that
            Patch: lines were stripped and renames were applied.
  clean     Remove the work directory.

Options:
  -h, --help  This message.

Environment:
  WORK_DIR    Override work directory (default: /tmp/<repo>-pipeline-test).
EOF
}

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
fi

REPO=""
STAGE="all"
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    *) REPO="$1" ;;
esac
if [[ $# -ge 2 ]]; then
    STAGE="$2"
fi

case "$REPO" in
    xen)
        SOURCE_REPO="https://github.com/TrenchBoot/xen.git"
        PKG_REPO="https://github.com/QubesOS/qubes-vmm-xen.git"
        UPSTREAM_URL="https://xenbits.xenproject.org/git-http/xen.git"
        UPSTREAM_TAG_FORMAT="RELEASE-%s"
        SPEC_IN="xen.spec.in"
        PREP_BRANCH="qubes-vmm-xen-with-patches-rebase-prep"
        DOWNSTREAM_BRANCH="aem-next"
        COMPONENT="vmm-xen"
        RENAMES=(--rename "config:config-qubesos")
        ;;
    grub)
        SOURCE_REPO="https://github.com/TrenchBoot/grub.git"
        PKG_REPO="https://github.com/QubesOS/qubes-grub2.git"
        UPSTREAM_URL="https://gitlab.freedesktop.org/gnu-grub/grub.git"
        UPSTREAM_TAG_FORMAT="grub-%s"
        SPEC_IN="grub2.spec.in"
        PREP_BRANCH="qubes-grub2-with-patches-rebase-prep"
        DOWNSTREAM_BRANCH="tb-dev"
        COMPONENT="grub2"
        RENAMES=()
        ;;
    *)
        echo "ERROR: unknown repo '$REPO' (expected: xen, grub)" >&2
        usage >&2
        exit 1
        ;;
esac

WORK_DIR="${WORK_DIR:-/tmp/$REPO-pipeline-test}"

banner() {
    echo
    echo "=============================================================="
    echo "=== [$REPO] $*"
    echo "=============================================================="
}

do_prep() {
    banner "prep: synthesize rebase base in $WORK_DIR"
    "$SCRIPT_DIR/prep-qubes-rebase.sh" \
        --work-dir "$WORK_DIR" \
        --source-repo "$SOURCE_REPO" \
        --pkg-repo "$PKG_REPO" \
        --upstream-url "$UPSTREAM_URL" \
        --upstream-tag-format "$UPSTREAM_TAG_FORMAT" \
        --spec-in "$SPEC_IN" \
        --prep-branch "$PREP_BRANCH"
}

do_rebase() {
    banner "rebase: $DOWNSTREAM_BRANCH onto $PREP_BRANCH (local)"
    if [[ ! -d "$WORK_DIR/src/.git" ]]; then
        echo "ERROR: $WORK_DIR/src is missing -- run '$0 $REPO prep' first" >&2
        return 1
    fi
    "$SCRIPT_DIR/rebase.sh" --local \
        "$WORK_DIR/src" \
        "$DOWNSTREAM_BRANCH" \
        "$PREP_BRANCH"
}

do_overlay() {
    banner "overlay: snapshot source and merge packaging"
    if [[ ! -d "$WORK_DIR/src/.git" || ! -d "$WORK_DIR/pkg" ]]; then
        echo "ERROR: $WORK_DIR/{src,pkg} missing -- run '$0 $REPO prep' first" >&2
        return 1
    fi

    local build_dir="$WORK_DIR/build"
    rm -rf "$build_dir"
    cp -a "$WORK_DIR/src" "$build_dir"

    local preferred="${DOWNSTREAM_BRANCH}-rebased"
    if git -C "$build_dir" rev-parse --verify "$preferred" &>/dev/null; then
        echo "[overlay] build branch: $preferred (rebase succeeded)"
        git -C "$build_dir" checkout "$preferred"
    else
        echo "[overlay] '$preferred' not found; using '$PREP_BRANCH' for smoke-test"
        git -C "$build_dir" checkout "$PREP_BRANCH"
    fi

    "$SCRIPT_DIR/overlay-packaging.sh" \
        --workspace "$build_dir" \
        --pkg "$WORK_DIR/pkg" \
        --spec-in "$SPEC_IN" \
        --component "$COMPONENT" \
        "${RENAMES[@]}"

    banner "overlay: verify results"
    local spec="$build_dir/$COMPONENT.spec.in"
    local patch_count
    patch_count=$(grep -c '^Patch' "$spec" || true)
    echo "  spec file      : $spec"
    echo "  Patch: lines   : $patch_count (expected: 0)"
    echo "  Source refs:"
    grep '^Source[0-9]*:' "$spec" | sed 's/^/    /'
    if [[ "$patch_count" != "0" ]]; then
        echo "FAIL: expected 0 Patch: lines, got $patch_count" >&2
        return 1
    fi
    for rename in "${RENAMES[@]}"; do
        if [[ "$rename" == "--rename" ]]; then continue; fi
        local dst="${rename#*:}"
        if [[ ! -e "$build_dir/$dst" ]]; then
            echo "FAIL: expected renamed file '$build_dir/$dst' to exist" >&2
            return 1
        fi
        echo "  rename applied : $dst"
    done
}

do_clean() {
    banner "clean: removing $WORK_DIR"
    rm -rf "$WORK_DIR"
}

case "$STAGE" in
    all)
        do_prep
        if ! do_rebase; then
            echo
            echo "NOTE: rebase stage exited non-zero (likely a conflict)." >&2
            echo "      Continuing with overlay against '$PREP_BRANCH' for smoke-test." >&2
        fi
        do_overlay
        ;;
    prep)    do_prep ;;
    rebase)  do_rebase ;;
    overlay) do_overlay ;;
    clean)   do_clean ;;
    *)
        echo "ERROR: unknown stage '$STAGE'" >&2
        usage >&2
        exit 1
        ;;
esac

banner "$STAGE: OK"
