#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

# Automated tests for the rebase/build pipeline scripts. Uses local file://
# git fixtures, so runs are fast, deterministic, and offline. No frameworks.
#
# Usage:
#   bash run-tests.sh           # run all tests
#   bash run-tests.sh <regex>   # run only tests matching regex
#
# Exit code: 0 on all-pass, 1 on any failure.

set -uo pipefail  # no -e; tests manage their own errors so all assertions run

# Isolate git from the developer's global/system config. Without this, the
# user's ~/.gitconfig (commit.gpgsign, rerere, rebase.autoStash, merge
# strategy defaults, diff.algorithm, etc.) leaks into fixture commits AND
# into `git rebase` invoked inside rebase.sh -- producing env-specific
# failures. Requires git >= 2.32 for GIT_CONFIG_GLOBAL; modern distros have it.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP_SCRIPT="$SCRIPTS_DIR/prep-qubes-rebase.sh"
OVERLAY_SCRIPT="$SCRIPTS_DIR/overlay-packaging.sh"
REBASE_SCRIPT="$SCRIPTS_DIR/rebase.sh"

# ============================================================================
# Assertion helpers
# ============================================================================
FAILED_ASSERTS=0
CURRENT_TEST=""

_fail() {
    FAILED_ASSERTS=$((FAILED_ASSERTS + 1))
    echo "    FAIL: $*" >&2
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values differ}"
    [[ "$expected" == "$actual" ]] && return 0
    _fail "$msg (expected='$expected', actual='$actual')"
    return 1
}

assert_ne() {
    local unexpected="$1" actual="$2" msg="${3:-values unexpectedly match}"
    [[ "$unexpected" != "$actual" ]] && return 0
    _fail "$msg (got='$actual')"
    return 1
}

assert_nonzero() {
    local rc="$1" msg="${2:-exit code should be non-zero}"
    [[ "$rc" -ne 0 ]] && return 0
    _fail "$msg (got rc=$rc)"
    return 1
}

assert_file() {
    local path="$1" msg="${2:-file missing}"
    [[ -e "$path" ]] && return 0
    _fail "$msg: $path"
    return 1
}

assert_no_file() {
    local path="$1" msg="${2:-file unexpectedly present}"
    [[ ! -e "$path" ]] && return 0
    _fail "$msg: $path"
    return 1
}

assert_grep() {
    local pattern="$1" file="$2" msg="${3:-pattern not found}"
    grep -qE "$pattern" "$file" && return 0
    _fail "$msg (file=$file, pattern=$pattern)"
    return 1
}

assert_no_grep() {
    local pattern="$1" file="$2" msg="${3:-pattern unexpectedly found}"
    grep -qE "$pattern" "$file" || return 0
    _fail "$msg (file=$file, pattern=$pattern)"
    return 1
}

# ============================================================================
# Fixtures -- local file:// git repos that mimic xen/grub pipeline inputs
# ============================================================================

# _fx_git: git wrapper that disables gpg signing and sets a fixed identity.
# Fixture commits must not depend on the developer's global git config
# (commit.gpgsign, user.name, user.email), since tests must be self-contained.
_fx_git() {
    git \
        -c commit.gpgsign=false \
        -c tag.gpgsign=false \
        -c user.name=fixture \
        -c user.email=fixture@local \
        "$@"
}

# make_upstream <dir> <tag>
#
# Creates a fake upstream repo with a tagged commit containing src/main.c and
# a config/ directory.
make_upstream() {
    local dir="$1" tag="$2"
    _fx_git init -q -b main "$dir"
    mkdir "$dir/src" "$dir/config"
    echo 'int main(void) { return 0; }' > "$dir/src/main.c"
    echo 'upstream default' > "$dir/config/defaults.txt"
    _fx_git -C "$dir" add .
    _fx_git -C "$dir" commit -q -m v1
    _fx_git -C "$dir" tag "$tag"
}

# make_pkg <dir> <version> <spec_filename> <upstream_dir>
#
# Creates a fake QubesOS packaging repo with:
#   - version file          (the version this packaging targets)
#   - two real patches      (generated via `git diff` against the upstream)
#   - a spec.in with Patch0, Patch1, Source3: config entries
#   - a config/ directory   (to exercise the rename-collision case)
make_pkg() {
    local dir="$1" version="$2" spec="$3" upstream="$4"
    _fx_git init -q -b main "$dir"
    echo "$version" > "$dir/version"
    echo "1" > "$dir/rel"

    # Generate real patches by mutating a scratch clone.
    local scratch
    scratch=$(mktemp -d)
    _fx_git clone -q "$upstream" "$scratch"

    sed -i 's/return 0;/return 42;/' "$scratch/src/main.c"
    _fx_git -C "$scratch" diff > "$dir/0001-change-return.patch"
    _fx_git -C "$scratch" checkout -q -- .

    echo "// extra" > "$scratch/src/extra.c"
    _fx_git -C "$scratch" add src/extra.c
    _fx_git -C "$scratch" diff --cached > "$dir/0002-add-extra.patch"

    rm -rf "$scratch"

    cat > "$dir/$spec" <<EOF
Name:    testpkg
Version: $version
Source0: testpkg-%{version}.tar.gz
Source3: config
Patch0:  0001-change-return.patch
Patch1:  0002-add-extra.patch
EOF

    mkdir "$dir/config"
    echo 'qubes-specific' > "$dir/config/qubes-opts.txt"

    _fx_git -C "$dir" add .
    _fx_git -C "$dir" commit -q -m initial
}

# make_source <dir> <upstream_dir> <branch> <base_tag>
#
# Creates a fake TrenchBoot-style source fork, with a downstream branch
# containing one extra commit on top of the given upstream tag.
make_source() {
    local dir="$1" upstream="$2" branch="$3" tag="$4"
    _fx_git clone -q "$upstream" "$dir"
    _fx_git -C "$dir" checkout -q -b "$branch" "$tag"
    echo 'downstream change' > "$dir/downstream.txt"
    _fx_git -C "$dir" add .
    _fx_git -C "$dir" commit -q -m downstream
}

# make_all_fixtures <base_dir>
#
# Populates upstream/, pkg/, source/ under <base_dir>. Echoes one var per line
# for the caller to `eval`.
make_all_fixtures() {
    local base="$1"
    make_upstream "$base/upstream" "RELEASE-1.0"
    make_pkg "$base/pkg" "1.0" "testpkg.spec.in" "$base/upstream"
    make_source "$base/source" "$base/upstream" "main-dev" "RELEASE-1.0"
}

# ============================================================================
# Tests
# ============================================================================

test_overlay_happy_path() {
    local tmp; tmp=$(mktemp -d)
    local pkg="$tmp/pkg" workspace="$tmp/workspace"
    mkdir -p "$pkg" "$workspace"

    cat > "$pkg/my.spec.in" <<'EOF'
Name:    foo
Patch0:  patch-a.patch
Patch15: patch-b.patch
Source3: config
EOF
    : > "$pkg/patch-a.patch"
    : > "$pkg/patch-b.patch"
    mkdir "$pkg/config"
    echo 'pkg-data' > "$pkg/config/file.txt"
    echo 'source code' > "$workspace/main.c"

    "$OVERLAY_SCRIPT" \
        --workspace "$workspace" --pkg "$pkg" \
        --spec-in my.spec.in --component foocomp \
        >/dev/null 2>&1
    assert_eq 0 "$?" "script should succeed"

    assert_file    "$workspace/foocomp.spec.in" "renamed spec should exist"
    assert_no_file "$workspace/my.spec.in"      "original spec name should be gone"
    assert_file    "$workspace/main.c"          "original source should be preserved"
    assert_file    "$workspace/patch-a.patch"   "patch files should be copied"
    assert_no_grep '^Patch[0-9]' "$workspace/foocomp.spec.in" "Patch: lines stripped"

    rm -rf "$tmp"
}

test_overlay_rename_updates_spec() {
    local tmp; tmp=$(mktemp -d)
    local pkg="$tmp/pkg" workspace="$tmp/workspace"
    mkdir -p "$pkg" "$workspace"

    cat > "$pkg/x.spec.in" <<'EOF'
Name:    foo
Source3: config
Source7: configured-thing
EOF
    mkdir "$pkg/config"
    echo 'data' > "$pkg/config/file.txt"

    "$OVERLAY_SCRIPT" \
        --workspace "$workspace" --pkg "$pkg" \
        --spec-in x.spec.in --component foo \
        --rename "config:config-renamed" \
        >/dev/null 2>&1
    assert_eq 0 "$?" "rename should succeed"

    assert_file    "$workspace/config-renamed/file.txt" "renamed dir should be present"
    assert_no_file "$workspace/config"                  "original dir name should be gone"
    assert_grep    '^Source3:[[:space:]]+config-renamed$' \
        "$workspace/foo.spec.in" "Source3: should point at rename target"
    # Source7 mentions "configured-thing" which contains "config" as substring --
    # the rename must NOT touch it.
    assert_grep    '^Source7:[[:space:]]+configured-thing$' \
        "$workspace/foo.spec.in" "unrelated Source: values should not be mangled"

    rm -rf "$tmp"
}

test_overlay_fails_on_missing_args() {
    "$OVERLAY_SCRIPT" --workspace /tmp </dev/null >/dev/null 2>&1
    assert_nonzero "$?" "missing required args should fail"
}

test_overlay_fails_on_missing_spec() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/pkg" "$tmp/workspace"
    "$OVERLAY_SCRIPT" \
        --workspace "$tmp/workspace" --pkg "$tmp/pkg" \
        --spec-in absent.spec.in --component foo \
        >/dev/null 2>&1
    assert_nonzero "$?" "missing spec-in should fail"
    rm -rf "$tmp"
}

test_prep_happy_path() {
    local tmp; tmp=$(mktemp -d)
    make_all_fixtures "$tmp"

    "$PREP_SCRIPT" \
        --work-dir "$tmp/work" \
        --source-repo "file://$tmp/source" \
        --pkg-repo    "file://$tmp/pkg" \
        --upstream-url "file://$tmp/upstream" \
        --upstream-tag-format 'RELEASE-%s' \
        --spec-in testpkg.spec.in \
        --prep-branch prep \
        >/dev/null 2>&1
    assert_eq 0 "$?" "prep should succeed"

    assert_file "$tmp/work/pkg/version" "pkg/version should exist"
    assert_eq "1.0" "$(cat "$tmp/work/pkg/version" 2>/dev/null)" "version should be 1.0"

    assert_eq "prep" "$(git -C "$tmp/work/src" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
        "HEAD should be on prep branch"

    # Patches were applied to the working tree.
    assert_grep "return 42" "$tmp/work/src/src/main.c" "first patch should be applied"
    assert_file "$tmp/work/src/src/extra.c"            "second patch should be applied"

    # Prep commit's parent is the upstream tag.
    local parent tag_sha
    parent=$(git -C "$tmp/work/src" rev-parse HEAD~1 2>/dev/null)
    tag_sha=$(git -C "$tmp/work/src" rev-list -n1 RELEASE-1.0 2>/dev/null)
    assert_eq "$tag_sha" "$parent" "prep commit parent should be upstream tag"

    rm -rf "$tmp"
}

test_prep_is_deterministic() {
    # Regression guard for the hardcoded GIT_*_DATE. Without a stable commit
    # hash, rebase.sh cannot detect "no-op" runs and every weekly cron would
    # do unnecessary work / force-pushes.
    local tmp; tmp=$(mktemp -d)
    make_all_fixtures "$tmp"

    "$PREP_SCRIPT" \
        --work-dir "$tmp/work1" \
        --source-repo "file://$tmp/source" \
        --pkg-repo    "file://$tmp/pkg" \
        --upstream-url "file://$tmp/upstream" \
        --upstream-tag-format 'RELEASE-%s' \
        --spec-in testpkg.spec.in \
        --prep-branch prep \
        >/dev/null 2>&1
    local h1; h1=$(git -C "$tmp/work1/src" rev-parse HEAD 2>/dev/null)

    # Cross a whole-second boundary before the second run. If determinism
    # relied on "now" rather than a fixed date, the two commits would land
    # in different seconds and the hashes would differ.
    sleep 2

    "$PREP_SCRIPT" \
        --work-dir "$tmp/work2" \
        --source-repo "file://$tmp/source" \
        --pkg-repo    "file://$tmp/pkg" \
        --upstream-url "file://$tmp/upstream" \
        --upstream-tag-format 'RELEASE-%s' \
        --spec-in testpkg.spec.in \
        --prep-branch prep \
        >/dev/null 2>&1
    local h2; h2=$(git -C "$tmp/work2/src" rev-parse HEAD 2>/dev/null)

    assert_ne "" "$h1" "first prep run should produce a commit"
    assert_eq "$h1" "$h2" "identical inputs must produce identical commit hash"

    rm -rf "$tmp"
}

test_prep_fails_on_bad_patch() {
    local tmp; tmp=$(mktemp -d)
    make_all_fixtures "$tmp"

    # Corrupt the second patch so it won't apply.
    cat > "$tmp/pkg/0002-add-extra.patch" <<'EOF'
--- a/does-not-exist.txt
+++ b/does-not-exist.txt
@@ -1 +1 @@
-x
+y
EOF
    # Re-commit the packaging change so the clone picks it up.
    _fx_git -C "$tmp/pkg" add -A
    _fx_git -C "$tmp/pkg" commit -q -m "bad patch"

    "$PREP_SCRIPT" \
        --work-dir "$tmp/work" \
        --source-repo "file://$tmp/source" \
        --pkg-repo    "file://$tmp/pkg" \
        --upstream-url "file://$tmp/upstream" \
        --upstream-tag-format 'RELEASE-%s' \
        --spec-in testpkg.spec.in \
        --prep-branch prep \
        >/dev/null 2>&1
    assert_eq 2 "$?" "unappliable patch should cause exit code 2 (documented contract)"

    rm -rf "$tmp"
}

test_prep_fails_on_missing_args() {
    "$PREP_SCRIPT" --work-dir /tmp </dev/null >/dev/null 2>&1
    assert_nonzero "$?" "prep should fail with missing args"
}

test_full_pipeline() {
    # prep -> rebase --local -> overlay, against fixtures where the
    # downstream branch does not conflict with the qubes patches.
    local tmp; tmp=$(mktemp -d)
    make_all_fixtures "$tmp"

    # Prep.
    "$PREP_SCRIPT" \
        --work-dir "$tmp/work" \
        --source-repo "file://$tmp/source" \
        --pkg-repo    "file://$tmp/pkg" \
        --upstream-url "file://$tmp/upstream" \
        --upstream-tag-format 'RELEASE-%s' \
        --spec-in testpkg.spec.in \
        --prep-branch prep \
        >/dev/null 2>&1
    assert_eq 0 "$?" "prep must succeed"

    # Rebase --local. Our downstream touches downstream.txt only; prep touches
    # src/main.c and src/extra.c; no conflict expected.
    "$REBASE_SCRIPT" --local "$tmp/work/src" main-dev prep >/dev/null 2>&1
    local rebase_rc=$?
    assert_eq 0 "$rebase_rc" "rebase must succeed without conflict"

    # Check the rebased branch exists.
    git -C "$tmp/work/src" rev-parse --verify main-dev-rebased &>/dev/null
    assert_eq 0 "$?" "main-dev-rebased branch should exist after rebase"

    # Overlay simulates what the build job does: check out rebased branch into
    # a scratch dir, merge packaging in.
    local build="$tmp/build"
    cp -a "$tmp/work/src" "$build"
    git -C "$build" checkout main-dev-rebased >/dev/null 2>&1

    "$OVERLAY_SCRIPT" \
        --workspace "$build" --pkg "$tmp/work/pkg" \
        --spec-in testpkg.spec.in --component testcomp \
        --rename "config:config-qubes" \
        >/dev/null 2>&1
    assert_eq 0 "$?" "overlay must succeed"

    # End-state assertions: the workspace is a valid qubes-builder component.
    assert_file    "$build/testcomp.spec.in"        "spec renamed to component"
    assert_file    "$build/config-qubes/qubes-opts.txt" "packaging config renamed in"
    assert_file    "$build/config/defaults.txt"     "source's own config dir preserved"
    assert_file    "$build/version"                 "version file overlaid from pkg"
    assert_file    "$build/downstream.txt"          "downstream changes preserved through rebase"
    assert_grep    "return 42"  "$build/src/main.c" "qubes patch carried through rebase"
    assert_no_grep '^Patch'     "$build/testcomp.spec.in" "Patch: lines stripped"
    assert_grep    '^Source3:[[:space:]]+config-qubes$' \
        "$build/testcomp.spec.in" "Source3 rewritten"

    rm -rf "$tmp"
}

# ============================================================================
# Runner
# ============================================================================

main() {
    local filter="${1:-.*}"
    local passed=0 failed=0

    local tests
    mapfile -t tests < <(compgen -A function | grep '^test_' | grep -E "$filter" | sort)

    if [[ ${#tests[@]} -eq 0 ]]; then
        echo "No tests match filter: $filter" >&2
        return 1
    fi

    for t in "${tests[@]}"; do
        CURRENT_TEST="$t"
        FAILED_ASSERTS=0
        echo "==> $t"
        "$t"
        if [[ $FAILED_ASSERTS -eq 0 ]]; then
            echo "    ok"
            passed=$((passed + 1))
        else
            echo "    $FAILED_ASSERTS assertion(s) failed" >&2
            failed=$((failed + 1))
        fi
    done

    echo
    echo "===================================="
    echo "$passed passed, $failed failed"
    echo "===================================="
    [[ $failed -eq 0 ]]
}

main "$@"
