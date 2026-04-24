#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

# Overlay a QubesOS packaging tree onto a source workspace at build time.
#
# Inputs:
#   --workspace DIR        Source workspace (e.g. checked-out TrenchBoot/xen at
#                          aem-next-rebased).
#   --pkg DIR              Packaging tree (e.g. cloned QubesOS/qubes-vmm-xen).
#   --spec-in NAME         Name of the spec-in file inside <pkg> (e.g. "xen.spec.in").
#   --component NAME       QubesOS component name (e.g. "vmm-xen"). The spec-in
#                          is renamed to "<component>.spec.in" in the output
#                          workspace to match qubes-builderv2 expectations.
#   --rename SRC:DST       Optional, repeatable. Before overlay, rename <pkg>/SRC
#                          to <pkg>/DST. Also updates matching "Source*: SRC"
#                          lines in the spec-in to reference DST. Use to resolve
#                          collisions between packaging and source file names
#                          (e.g. xen's packaging "config" dir vs xen source's
#                          own "config" dir).
#   --commit               After overlay, git-commit the result inside the
#                          workspace so qubes-builderv2 sees a clean tree.
#                          Requires <workspace> to be a git repo.
#   -h, --help             Print this help.
#
# Behaviour:
#   1. Apply --rename operations inside <pkg>. Update "Source*:" references in
#      <pkg>/<spec-in> accordingly.
#   2. Strip all "Patch[0-9]*:" lines from <pkg>/<spec-in>. Rationale: all
#      qubes patches are already applied as commits in <workspace> (that is
#      what prep-qubes-rebase.sh and the subsequent rebase accomplish). If
#      rpmbuild tried to re-apply them, it would fail.
#   3. Copy every file from <pkg> into <workspace> (overwriting any name
#      collisions).
#   4. Rename <workspace>/<spec-in> to <workspace>/<component>.spec.in if the
#      names differ.
#   5. Optionally commit, so that the workspace is a valid qubes-builderv2
#      component tree.
#
# Runs identically on a developer laptop and in CI.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --workspace DIR   Source workspace directory.
  --pkg DIR         Packaging directory (already cloned).
  --spec-in NAME    Spec-in filename inside <pkg>.
  --component NAME  QubesOS component name.

Optional:
  --rename SRC:DST  Rename SRC to DST inside <pkg> before overlay
                    (repeatable).
  --commit          Commit the overlay in <workspace> (requires git repo).
  -h, --help        Show this help.
EOF
}

WORKSPACE=""
PKG=""
SPEC_IN=""
COMPONENT=""
COMMIT=""
RENAMES=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --pkg)       PKG="$2"; shift 2 ;;
        --spec-in)   SPEC_IN="$2"; shift 2 ;;
        --component) COMPONENT="$2"; shift 2 ;;
        --rename)    RENAMES+=("$2"); shift 2 ;;
        --commit)    COMMIT="true"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

missing=0
for var in WORKSPACE PKG SPEC_IN COMPONENT; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --${var,,} is required" >&2
        missing=1
    fi
done
if [[ $missing -ne 0 ]]; then
    usage >&2
    exit 1
fi

[[ -d "$WORKSPACE" ]] || { echo "ERROR: workspace '$WORKSPACE' is not a directory" >&2; exit 1; }
[[ -d "$PKG" ]]       || { echo "ERROR: pkg '$PKG' is not a directory" >&2; exit 1; }
[[ -f "$PKG/$SPEC_IN" ]] || { echo "ERROR: '$PKG/$SPEC_IN' not found" >&2; exit 1; }

echo "[overlay] workspace : $WORKSPACE"
echo "[overlay] pkg       : $PKG"
echo "[overlay] spec-in   : $SPEC_IN"
echo "[overlay] component : $COMPONENT"

for rename in "${RENAMES[@]}"; do
    src="${rename%%:*}"
    dst="${rename#*:}"
    if [[ -z "$src" || -z "$dst" || "$src" == "$rename" ]]; then
        echo "ERROR: --rename argument '$rename' is not in SRC:DST form" >&2
        exit 1
    fi
    if [[ ! -e "$PKG/$src" ]]; then
        echo "ERROR: rename source '$PKG/$src' does not exist" >&2
        exit 1
    fi
    echo "[overlay] rename: $src -> $dst"
    mv "$PKG/$src" "$PKG/$dst"
    # Update matching "Source*: <src>" lines in the spec-in.
    escaped_src=$(printf '%s' "$src" | sed 's/[.[\*^$/]/\\&/g')
    sed -i -E "s|^(Source[0-9]*:[[:space:]]+)${escaped_src}([[:space:]]*)$|\1${dst}\2|" "$PKG/$SPEC_IN"
done

echo "[overlay] stripping Patch[0-9]*: lines from $SPEC_IN"
sed -i '/^Patch[0-9]*:/d' "$PKG/$SPEC_IN"

echo "[overlay] copying $PKG/* onto $WORKSPACE/..."
# Use dot-glob so hidden files are copied; -a preserves perms & timestamps.
cp -a "$PKG/." "$WORKSPACE/"

out_spec="$COMPONENT.spec.in"
if [[ "$SPEC_IN" != "$out_spec" ]]; then
    echo "[overlay] renaming $SPEC_IN -> $out_spec in workspace"
    mv "$WORKSPACE/$SPEC_IN" "$WORKSPACE/$out_spec"
fi

if [[ "$COMMIT" == "true" ]]; then
    if [[ ! -d "$WORKSPACE/.git" ]]; then
        echo "ERROR: --commit requested but '$WORKSPACE' is not a git working tree" >&2
        exit 1
    fi
    echo "[overlay] committing overlay in workspace..."
    git -C "$WORKSPACE" \
        -c user.name="overlay-packaging" \
        -c user.email="overlay-packaging@local" \
        add -A
    git -C "$WORKSPACE" \
        -c user.name="overlay-packaging" \
        -c user.email="overlay-packaging@local" \
        commit --no-gpg-sign -m "Overlay QubesOS packaging for $COMPONENT build"
fi

echo "[overlay] Done."
