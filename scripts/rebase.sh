#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

trap error_handling EXIT

set -euo pipefail

# Help
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <first_repo> <first_repo_branch> <second_repo> <second_repo_branch>

Rebase a branch from the first repo onto a branch from the second repo. On
conflict, stops the rebase and creates a conflict branch containing all commits
that rebased cleanly before the conflict.

Note, that this script supports only HTTPS protocol for fetching remote
repositories.

A developer then needs to solve the conflict manually according to the following
steps:
1. (For remote repos only) fetch the remote repository.
2. Enter the repository.
3. Checkout the conflict branch created by the script (check the conflict branch
  naming below).
4. Cherry-pick the commit that introduced the conflict (the hash of the commit
  will be reported by the script or will be a part of the conflict branch name).
5. Solve the conflict and apply the commit after solving the conflict on top of
  the conflict branch (e.g., by using "git cherry-pick --continue").
6. (For remote repos only) push the remote repository.
7. Try to do the rebase with this script again and wait either for a new
  conflict or for the rebase to be finished.

The steps will be accompanied by commands when printed by script when prompting
for conflict resolution.

In case the --first-remote-token option is provided - the script will do the
following actions on the remote part of the first repository:
* Fetch the first repository using the TOKEN. The second repository will be
  fetched using HTTPS without tokens or credentials.
* Will push and delete pushed by this script branches using the TOKEN on the
  remote repository. The script will push and delete only the conflict branches.
  And when the rebase will succeed it will push a branch with rebased commits
  from the <first_repo_branch> on top of the <second_repo_branch> named
  '<first_repo_branch>-rebased'.
* Will create a PR from a conflict branch to the <first_repo_branch> in case of
  conflicts.

Currently supported remotes:
* GitHub.

Arguments:
  first_repo     HTTPS URL of the fork repository to clone, or path to the local
                 repository
  first_repo_branch
                 Branch in the fork to rebase
  second_repo    HTTPS URL of the upstream repository to clone
  second_repo_branch
                 Branch in the upstream to rebase onto

Options:
  -h, --help        Show this help message and exit
  -l, --local       Treat the <first_repo> as local directory path and
                    skips <second_repo>.
  -s, --skip N      Skip the first N commits of <first_repo_branch> that come
                    after the common ancestor with <second_repo_branch>. The
                    skipped commits are dropped from the rebase result entirely.
                    The same value must be passed on every continuation run,
                    otherwise the conflict-resolution check will not be able to
                    determine whether the conflict was resolved correctly.
  --first-remote-token TOKEN
                    Access token for the user to access the first repository on
                    the remote.
  --commit-user-name NAME
                    The name used for "git config user.name". If not provided -
                    the "github-actions[bot]" is being used as the default name.
                    This name is used when creating new commits during rebase.
  --commit-user-email EMAIL
                    The email used for "git config user.email". If not provided -
                    the "github-actions[bot]@users.noreply.github.com" is being
                    used as default email. This email is used when creating new
                    commits during rebase.
  --cicd-trigger-resume MESSAGE
                    When using the script with --first-remote-token, the script
                    creates a PR on the remote part of the <first_repo> with a
                    comment on how to resolve the conflict correctly. But by
                    default, the comment does not contain a message on how to
                    resume the automatic rebase with this script when the script
                    is used in CI/CD. The reason this information is missing is
                    that this script should not depend by default on whether
                    it is launched in CI/CD or not, hence this script by default
                    expects that it will be launched from a CLI. Hence, CI/CD
                    launches this script as a step in a job as a BASH script.
                    Hence, it is for the CI/CD configuration to determine when
                    the CI/CD is triggered. It might be when a developer pushes
                    to the conflict branch, closes the created by this script
                    PR, etc. So the CI/CD configuration can communicate to the
                    developer via the MESSAGE how to relaunch automatic rebase
                    after resolving the conflict.
  -v, --verbose     Print a lot of debug information.
                    Note: token value will be visible in output.

Conflict branch naming:
  <first_repo_branch>-<40-char-hash-of-conflicting-commit>-conflict

Exit codes:
  0   Rebase completed successfully
  1   Some other issue encountered
  2   Conflict encountered (conflict branch created)
  3   Script logic failure
  4   Multiple conflict branches found
  5   No rebase needed
  6   The last successful rebase has not been managed properly.

The error code "4" means the git history of the first repository contains
several branches that match the conflict branch naming described above, but the
names differ by the commit hash. Script uses the commit hash as a base for
creating commits during rebase, and when it sees several commit hashes, it
cannot continue as it does not have any logic to decide which commit hash to
use. In such a case, the developer should either delete all the conflict
branches and start the rebase with this script over, or delete all the conflict
branches except the correct one and try to continue rebasing with this script.

Example:
  $(basename "$0") \\
    https://github.com/you/my-fork.git     my-feature \\
    https://github.com/org/upstream.git    main
EOF
}

# This function pushes a branch to a remote repository. Return codes:
# 0: Success.
# 1: Some issue.
push_branch_remote() {
    local token="$1"
    local branch="$2"
    local remote="$3"

    # The remote URL must contain the token for the ref to be modified on the
    # remote via personal access token authentication:
    git remote get-url "$remote" 2> "$TMP_LOG_FILE" | grep -F "$token" &> "$TMP_LOG_FILE" || return 1
    git push "$remote" "$branch" &> "$TMP_LOG_FILE" || return 1

    return 0
}

# This function deletes a branch on a remote repository. Return codes:
# 0: Success.
# 1: Some issue.
# 2: The function tried to delete a branch that was not created by this script
# and probably belongs to somebody else.
delete_branch_remote() {
    local token="$1"
    local branch="$2"
    local remote="$3"
    local temp=""
    local commit=""

    # Some checks to make sure that we are deleting the branch created by this
    # script and not some other branch:
    # 1. The branch must match the pattern for branches with conflicts that are
    # created by this script:
    echo "$branch" | grep -E '.*-[a-z0-9]{40}-conflict' &> "$TMP_LOG_FILE" || return 2
    # 2. The branch name must contain a hash of existing commit
    temp="${branch%-conflict}"
    commit="${temp##*-}"
    git show "$commit" &> "$TMP_LOG_FILE" || return 2
    # The checks above are reasonable but not sufficient, as there is a
    # probability that a branch that will match the pattern will be created by a
    # user. At git level we do not have access to the information on who created
    # the branch. But if we have access the following check could be implemented
    # (the "could be" means it has not been tested yet):
    #
    # curl -H "Authorization: Bearer $token" \
    #   "https://api.github.com/orgs/<org>/audit-log?phrase=create+branch"
    #
    # This check seems to require organization level access for the token.

    # The remote URL must contain the token for the ref to be modified on the
    # remote via personal access token authentication:
    git remote get-url "$remote" 2> "$TMP_LOG_FILE" | grep -F "$token" &> "$TMP_LOG_FILE" || return 1
    git push "$remote" --delete "$branch" &> "$TMP_LOG_FILE" || return 1

    return 0
}

# This function creates a PR on the remote repository. Return codes:
# 0: Success.
# 1: Some issue.
# 2: PR was not created.
create_pr_remote() {
    local token="$1"
    local repo_url="$2"
    local head_branch="$3"
    local base_branch="$4"
    local pr_title="$5"
    local pr_body="$6"
    local payload repo_path owner repo_name response http_code pr_url body


    # Derive owner/repo from the URL (supports
    # https://github.com/OWNER/REPO[.git]):
    repo_path="$(echo "$repo_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
    owner="$(cut -d'/' -f1 <<< "$repo_path")"
    repo_name="$(cut -d'/' -f2 <<< "$repo_path")"
    local api_url="https://api.github.com/repos/${owner}/${repo_name}/pulls"

    if [[ -z "$owner" || -z "$repo_name" ]]; then
        echo "ERROR: Could not parse owner/repo from URL: $repo_url" >&2
        return 1
    fi

    if [[ -z "$pr_title" || -z "$pr_body" ]]; then
        echo "ERROR: No PR title and/or PR body provided" >&2
        return 1
    fi

    if command -v jq &>/dev/null; then
        payload="$(jq -n \
            --arg title "$pr_title" \
            --arg head  "$head_branch" \
            --arg base  "$base_branch" \
            --arg body  "$pr_body" \
            '{title: $title, head: $head, base: $base, body: $body}')"
    elif command -v python3 &>/dev/null; then
        payload="$(python3 -c "
import json, sys
print(json.dumps({
    'title': sys.argv[1],
    'head':  sys.argv[2],
    'base':  sys.argv[3],
    'body':  sys.argv[4],
}))" "$pr_title" "$head_branch" "$base_branch" "$pr_body")"
    else
        echo "ERROR: jq or python3 is required to work on the JSON payload." >&2
        return 1
    fi

    response="$(curl -s -w "\n%{http_code}" \
        -X POST "$api_url" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${token}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "$payload")"

    http_code="$(tail -n1 <<< "$response")"
    body="$(head -n -1 <<< "$response")"

    if [[ "$http_code" != "201" ]]; then
        echo "ERROR: GitHub API returned HTTP ${http_code}:" >&2
        echo "$response" >&2
        return 1
    fi

    if command -v jq &>/dev/null; then
        pr_url="$(jq -r '.html_url' <<< "$body")"
    elif command -v python3 &>/dev/null; then
        pr_url="$(python3 -c "import json,sys; print(json.load(sys.stdin)['html_url'])" <<< "$body")"
    else
        echo "ERROR: jq or python3 is required to work on the JSON payload." >&2
        return 1
    fi

    echo "Pull request created: ${pr_url}"

    return 0
}

error_handling() {
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: $BASH_COMMAND failed!" >&2
        echo -e "The logs from the last executed command:\n" >&2
        [ -f "${TMP_LOG_FILE:-}" ] && cat "$TMP_LOG_FILE" >&2
    fi

    rm -f "${TMP_LOG_FILE:-}"
    rm -rf "${WORK_DIR:-}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -v|--verbose)
        set -x
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -l|--local)
        LOCAL="true"
        shift
        ;;
      -s|--skip)
        SKIP="$2"
        shift 2
        ;;
      --first-remote-token)
        TOKEN="$2"
        shift 2
        ;;
      --commit-user-name)
        COMMIT_USER_NAME="$2"
        shift 2
        ;;
      --commit-user-email)
        COMMIT_USER_EMAIL="$2"
        shift 2
        ;;
      --cicd-trigger-resume)
        CICD_TRIGGER_RESUME="$2"
        shift 2
        ;;
      -*)
        echo "ERROR: Unknown option $1" >&2
        usage
        exit 1
        ;;
      *)
        POSITIONAL_ARGS+=( "$1" )
        shift
        ;;
    esac
  done
}

# This function prepares remote repository URL for usage via GitHub's personal
# access token authentication. Return codes:
# 0: Success.
# 1: No HTTPS protocol prefix found in the remote repository URL.
build_url_with_token() {
    local url="$1"
    local token="$2"
    local repo_path

    # The limit on HTTPS only is because of the personal access token that is
    # used here and works only over HTTPS:
    echo "$url" | grep 'https://' &> "$TMP_LOG_FILE" || return 1

    repo_path="$(echo "$url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
    echo "https://$token@github.com/$repo_path.git" 2> "$TMP_LOG_FILE"

    return 0
}

# This function checks whether a rebase is needed. Return codes:
# 0: Rebase is needed.
# 1: Rebase is not needed.
check_for_rebase() {
    local head_ref="$1"
    local newbase="$2"
    local result

    result="$(git log "$head_ref".."$newbase" --oneline 2> "$TMP_LOG_FILE")"

    if [[ -z "$result" ]]; then
        return 1
    fi

    return 0
}

# This function checks whether a PR from branch A to branch B exists and is open
# on remote. Return codes:
# 0: Does exist.
# 1: Does not exist.
check_for_pr() {
    local token="$1"
    local repo_url="$2"
    local branch1="$3"
    local branch2="$4"
    local result=1
    local response repo_path owner repo_name

    # Derive owner/repo from the URL (supports
    # https://github.com/OWNER/REPO[.git]):
    repo_path="$(echo "$repo_url" | sed -E 's|.*github\.com[:/]||; s|\.git$||')"
    owner="$(cut -d'/' -f1 <<< "$repo_path")"
    repo_name="$(cut -d'/' -f2 <<< "$repo_path")"
    local api_url="https://api.github.com/repos/${owner}/${repo_name}/pulls"

    response="$(curl -s -H "Authorization: Bearer $token" \
  "$api_url?head=$owner:$branch1&base=$branch2&state=open")"

    # The conclusion is based on the response body length. If the response
    # contains any objects - PR exists, if not - PR does not exist.
    if command -v jq &>/dev/null; then
        result="$(jq 'length' <<< "$response")"
    elif command -v python3 &>/dev/null; then
        result="$(python3 -c "import sys, json; print(len(json.load(sys.stdin)))" <<< "$response")"
    fi

    if [ "$result" -eq 0 ]; then
        return 1
    fi

    return 0
}


# This function takes a GitHub repository HTTPS URL and converts it to GitHub
# SSH url format. Return codes:
# 0: Success. The function STDOUT contains the url in SSH format.
# 1: The URL is not a valid HTTPS url. The STDOUT is empty.
# 2: The URL is not a valid GitHub HTTPS repo url. The STDOUT is empty.
convert_https_to_ssh() {
    local url="$1"

    if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
        return 1
    fi

    if [[ ! "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$ ]]; then
        return 2
    fi

    echo "$url" | sed -E -e 's#^https://github\.com/#git@github.com:#' -e 's#/?(\.git)?/?$#.git#'
}

# Construct a URL to a branch on some git remote service using repo URL as a
# first argument and the branch name as a second argument. Return codes:
# 0: Success.
# 1: Error.
construct_branch_url() {
    local repo="$1"
    local branch="$2"

    # Currently only GitHub is supported:
    repo="${repo%.git}"
    echo "$repo/tree/$branch" && return 0

    return 1
}

# This function checks if conflict has been resolved and the commit with the
# resolved conflict is present on the conflict branch. Return codes:
# 0: The conflict is resolved and the commit is present.
# 1: The conflict is not resolved or the commit is not present. Or in some other
# undefined state.
#
# The optional 4th argument is the hash of the last commit that was skipped
# during the initial rebase (i.e., the N-th commit after the common ancestor on
# the first_repo_branch). When provided, the count of "original" commits is
# taken from after this commit instead of from the new base, because the first
# N commits of the original branch never get replayed onto the conflict branch.
check_if_resolved() {
    local head_ref="$1"
    local base="$2"
    local newbase="$3"
    local skip_commit="${4:-}"
    local commits1 commits1_num commits2 commits2_num

    commits1="$(git log "$newbase".."$head_ref" --oneline)"
    if [[ -n "$skip_commit" ]]; then
        commits2="$(git log "$skip_commit".."$base" --oneline)"
    else
        commits2="$(git log "$newbase".."$base" --oneline)"
    fi

    commits1_num=$(printf '%s' "$commits1" | grep -c '.' )
    commits2_num=$(printf '%s' "$commits2" | grep -c '.' )

    if [[ $commits1_num -eq $commits2_num ]]; then
        return 0
    fi

    return 1
}

# This function checks for empty commits between two refs. There is no return
# values. Instead it prints a list of empty commits to the STDOUT.
check_for_empty_commits() {
    local base="$1"
    local head_ref="$2"
    local commits=""
    local temp=""

    temp="$(git log "$base".."$head_ref" --format="%H %s" 2> "$TMP_LOG_FILE")"
    while IFS= read -r sha msg; do
        [ -z "$(git diff-tree --no-commit-id -r "$sha" 2> "$TMP_LOG_FILE")" ] \
            && commits+="
$sha $msg"
    done <<< "$temp"

    echo "$commits"
}

# Configuration and initial values:
declare -a BRANCHES
declare BRANCH_TEMP
LOCAL=""
TOKEN=""
BRANCH=""
COMMIT=""
SKIP="0"
SKIP_COMMIT=""
COMMIT_USER_NAME="github-actions[bot]"
COMMIT_USER_EMAIL="github-actions[bot]@users.noreply.github.com"
CICD_TRIGGER_RESUME=""
REBASE_HEAD_FILE=".git/REBASE_HEAD"
TMP_LOG_FILE="$(mktemp)"
ALL_ARGS="$@"


POSITIONAL_ARGS=()
parse_args "$@"
set -- "${POSITIONAL_ARGS[@]}"

if [[ "${#POSITIONAL_ARGS[@]}" -lt "2" ]]; then
    usage
    exit 1
fi
FIRST_REPO="$1"
FIRST_REPO_BRANCH="$2"
FIRST_REPO_REMOTE_NAME="origin"
if [[ -z "$LOCAL" ]]; then
    if [[ "${#POSITIONAL_ARGS[@]}" -ne "4" ]]; then
        usage
        exit 1
    fi
    SECOND_REPO="$3"
    SECOND_REPO_BRANCH="$4"
    SECOND_REPO_REMOTE_NAME="second-repo"
    SECOND_REPO_REF="$SECOND_REPO_REMOTE_NAME/$SECOND_REPO_BRANCH"
    WORK_DIR=$(mktemp -d)
    REPO_DIR="$WORK_DIR/repo"
    first_repo_branch="$(construct_branch_url "$FIRST_REPO" "$FIRST_REPO_BRANCH")"
    second_repo_branch="$(construct_branch_url "$SECOND_REPO" "$SECOND_REPO_BRANCH")"
    rebased_branch="$(construct_branch_url "$FIRST_REPO" "$FIRST_REPO_BRANCH-rebased")"

    SUCCESSFUL_REBASE_PR_TITLE="Automatic rebase of branch '$FIRST_REPO_BRANCH' completed successfully"
    SUCCESSFUL_REBASE_MESSAGE="Summary:
* Rebased branch [$FIRST_REPO_BRANCH]($first_repo_branch) from repository $FIRST_REPO.
* New base: [$SECOND_REPO_BRANCH]($second_repo_branch) from repository $SECOND_REPO.

Please, manage the rebased branch by either merging [$FIRST_REPO_BRANCH-rebased]($rebased_branch) into [$FIRST_REPO_BRANCH]($first_repo_branch), force pushing branch [$FIRST_REPO_BRANCH]($first_repo_branch) to include commits from [$FIRST_REPO_BRANCH-rebased]($rebased_branch), or any other way suitable for this repository.

Delete the branch [$FIRST_REPO_BRANCH-rebased]($rebased_branch) after you are done.
"
    unset first_repo_branch
    unset second_repo_branch
    unset rebased_branch
else
    if [[ "${#POSITIONAL_ARGS[@]}" -ne "3" ]]; then
        usage
        exit 1
    fi
    SECOND_REPO_BRANCH="$3"
    SECOND_REPO_REF="$SECOND_REPO_BRANCH"
    REPO_DIR="$FIRST_REPO"
    SUCCESSFUL_REBASE_MESSAGE="Summary:
* Rebased branch '$FIRST_REPO_BRANCH'.
* New base: '$SECOND_REPO_BRANCH'.

Please, manage the rebased branch by either merging '$FIRST_REPO_BRANCH-rebased'
into '$FIRST_REPO_BRANCH', force pushing branch '$FIRST_REPO_BRANCH' to include
commits from '$FIRST_REPO_BRANCH-rebased', or any other way suitable for this
repository.

Delete the branch '$FIRST_REPO_BRANCH-rebased' after you are done.
"
fi

echo "Working directory: $REPO_DIR"

################################################################################
# Repositories preparation
################################################################################
# Clone first repo and checkout branch:
if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
    repo_path="$(build_url_with_token "$FIRST_REPO" "$TOKEN")"

    echo "Cloning the first repository: $FIRST_REPO..."
    git clone "$repo_path" "$REPO_DIR" &> "$TMP_LOG_FILE"
    cd "$REPO_DIR" &> "$TMP_LOG_FILE"
    git fetch --all &> "$TMP_LOG_FILE"
    cd - &> "$TMP_LOG_FILE"
    unset repo_path
elif [[ "$LOCAL" != "true" ]]; then
    echo "Cloning the first repository: $FIRST_REPO..."
    git clone "$FIRST_REPO" "$REPO_DIR" &> "$TMP_LOG_FILE"
fi

echo "Checking out branch '$FIRST_REPO_BRANCH'..."
cd "$REPO_DIR" &> "$TMP_LOG_FILE"
git checkout "$FIRST_REPO_BRANCH" &> "$TMP_LOG_FILE"

echo "Setting user name to $COMMIT_USER_NAME for commits..."
git config user.name "$COMMIT_USER_NAME" &> "$TMP_LOG_FILE"
echo "Setting user email to $COMMIT_USER_EMAIL for commits..."
git config user.email "$COMMIT_USER_EMAIL" &> "$TMP_LOG_FILE"

# Add second repo as a remote:
if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
    echo "Adding second repo as a remote $SECOND_REPO..."
    git remote add "$SECOND_REPO_REMOTE_NAME" "$SECOND_REPO" &> "$TMP_LOG_FILE"
    unset repo_path

    echo "Fetching from the second repo branch '$SECOND_REPO_BRANCH'..."
    git fetch "$SECOND_REPO_REMOTE_NAME" "$SECOND_REPO_BRANCH" &> "$TMP_LOG_FILE"
elif [[ "$LOCAL" != "true" ]]; then
    echo "Adding second repo as a remote $SECOND_REPO..."
    git remote add "$SECOND_REPO_REMOTE_NAME" "$SECOND_REPO" &> "$TMP_LOG_FILE"

    echo "Fetching from the second repo '$SECOND_REPO_BRANCH'..."
    git fetch "$SECOND_REPO_REMOTE_NAME" "$SECOND_REPO_BRANCH" &> "$TMP_LOG_FILE"
fi

################################################################################
# Resolve the commit at which the rebase should actually start (skip support)
################################################################################
# When --skip N is provided, the first N commits of FIRST_REPO_BRANCH after the
# common ancestor with SECOND_REPO_REF are dropped from the rebase entirely. We
# resolve the N-th commit here (the *last* commit that gets skipped) so it can
# be used as the rebase upstream and as a lower bound for check_if_resolved().
if [[ "$SKIP" -gt 0 ]]; then
    MERGE_BASE="$(git merge-base "$FIRST_REPO_BRANCH" "$SECOND_REPO_REF" 2> "$TMP_LOG_FILE")"
    SKIP_COMMIT="$(git rev-list --reverse "$MERGE_BASE..$FIRST_REPO_BRANCH" 2> "$TMP_LOG_FILE" | sed -n "${SKIP}p")"

    if [[ -z "$SKIP_COMMIT" ]]; then
        echo "ERROR: --skip $SKIP requested but '$FIRST_REPO_BRANCH' has fewer than
$SKIP commits after the common ancestor with '$SECOND_REPO_REF'." >&2
        exit 1
    fi

    echo "Skipping the first $SKIP commit(s) after the common ancestor. Last skipped
commit: $SKIP_COMMIT"
fi

################################################################################
# Rebasing decision logic
################################################################################
# Check if there is a FIRST_REPO_BRANCH-rebased branch. If yes - do not start a
# new rebase, as the last successful rebase was not managed properly.
if [[ "$LOCAL" != "true" ]]; then
    BRANCH_TEMP=$(git branch -r --no-column --list "$FIRST_REPO_REMOTE_NAME"/"$FIRST_REPO_BRANCH"-rebased 2> "$TMP_LOG_FILE")
else
    BRANCH_TEMP=$(git branch --no-column --list "$FIRST_REPO_BRANCH"-rebased 2> "$TMP_LOG_FILE")
fi

if echo "$BRANCH_TEMP" | grep rebased &> "$TMP_LOG_FILE"; then
    echo "The last successful rebase of the branch '$FIRST_REPO_BRANCH' is still
present in the repository history. Please merge or delete it and restart the
automatic rebase."
    exit 6
fi
unset BRANCH_TEMP

# Check state we are in. Checks, if this is the first rebase attempt or a
# consequently triggered after a manual conflict resolution rebase attempt.
# Search for a previous branch with a conflict:
if [[ "$LOCAL" != "true" ]]; then
    BRANCH_TEMP=$(git branch -r --no-column --list "$FIRST_REPO_REMOTE_NAME"/"$FIRST_REPO_BRANCH"-*-conflict 2> "$TMP_LOG_FILE")
else
    BRANCH_TEMP=$(git branch --no-column --list "$FIRST_REPO_BRANCH"-*-conflict 2> "$TMP_LOG_FILE")
fi

while IFS= read -r line; do
    BRANCHES+=("$line")
done <<< "$BRANCH_TEMP"
unset BRANCH_TEMP

if [[ "${#BRANCHES[@]}" == "1" && -n "${BRANCHES[0]}" ]]; then
    if [[ "$LOCAL" != "true" ]]; then
        BRANCH="${BRANCHES[0]##*/}"
        git checkout -b "$BRANCH" "$FIRST_REPO_REMOTE_NAME/$BRANCH"
    else
        BRANCH="${BRANCHES[0]##* }"
    fi
    echo "Continuing rebase of the branch '$FIRST_REPO_BRANCH' from the last commit in
branch '$BRANCH'..."
    temp="${BRANCH%-conflict}"
    COMMIT="${temp##*-}"
elif [[ "${#BRANCHES[@]}" == "1" && -z "${BRANCHES[0]}" ]]; then
    echo "Starting a new rebase..."
else
    echo "ERROR: Repository has several conflict branches for the '$FIRST_REPO_BRANCH'
and needs cleanup, exiting..." >&2
    exit 4
fi
unset BRANCHES

################################################################################
# Attempt/continue rebase
################################################################################
if [[ -z "$COMMIT" && -z "$BRANCH" ]]; then
    if ! check_for_rebase "$FIRST_REPO_BRANCH" "$SECOND_REPO_REF"; then
        echo "Current branch '$FIRST_REPO_BRANCH' is up to date with
'$SECOND_REPO_REF'."
        exit 5
    fi

    # The check_if_resolved() function checks whether the conflict has been
    # resolved by comparing the number of commits on the conflict branch, the
    # default behavior of the git rebase is to drop empty commits that are there
    # result of rebase operation. This could mess up the check_if_resolved().
    # Hence, we better keep the empty commits on the branch but inform the
    # developer about them.
    #
    # When --skip N is in effect, we use `--onto SECOND_REPO_REF SKIP_COMMIT
    # FIRST_REPO_BRANCH` so that commits in MERGE_BASE..SKIP_COMMIT are excluded
    # from the rebase. Without --skip we fall back to the plain form.
    if [[ -n "$SKIP_COMMIT" ]]; then
        rebase_cmd=(git rebase --empty=keep --onto "$SECOND_REPO_REF" "$SKIP_COMMIT" "$FIRST_REPO_BRANCH")
    else
        rebase_cmd=(git rebase --empty=keep "$SECOND_REPO_REF")
    fi
    if "${rebase_cmd[@]}" &> "$TMP_LOG_FILE"; then
        echo "Rebase completed successfully. No conflicts."

        # Do not push to the same branch on the remote repository to avoid
        # force pushes:
        git checkout -b "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_BRANCH" &> "$TMP_LOG_FILE"
        empty_commits="$(check_for_empty_commits "$SECOND_REPO_REF" "$FIRST_REPO_BRANCH-rebased")"

        if [ -n "$empty_commits" ]; then
            SUCCESSFUL_REBASE_MESSAGE+="
There are empty commits:

$empty_commits

You might want to drop them."
        fi

        if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
            push_branch_remote "$TOKEN" "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_REMOTE_NAME"
            if ! check_for_pr "$TOKEN" "$FIRST_REPO" "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_BRANCH" ; then
                create_pr_remote "$TOKEN" "$FIRST_REPO" "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_BRANCH" "$SUCCESSFUL_REBASE_PR_TITLE" "$SUCCESSFUL_REBASE_MESSAGE"
            fi
        else
            echo "$SUCCESSFUL_REBASE_MESSAGE"
        fi
        exit 0
    fi
elif [[ -n "$COMMIT" && -n "$BRANCH" ]]; then
    if ! check_if_resolved "$BRANCH" "$COMMIT" "$SECOND_REPO_REF" "$SKIP_COMMIT"; then
        echo "ERROR: still a conflict." >&2
        exit 2
    fi

    echo "Continuing rebase '$FIRST_REPO_BRANCH' onto '$BRANCH' using commit
$COMMIT as a base..."

    # The check_if_resolved() function checks whether the conflict has been
    # resolved by comparing the number of commits on the conflict branch, the
    # default behavior of the git rebase is to drop empty commits that are there
    # result of rebase operation. This could mess up the check_if_resolved().
    # Hence, we better keep the empty commits on the branch but inform the
    # developer about them.
    if git rebase --empty=keep --onto "$BRANCH" "$COMMIT" "$FIRST_REPO_BRANCH" &> "$TMP_LOG_FILE"; then
        # Delete the temporary conflict branch so there is no leftovers after a
        # success:
        git branch --delete "$BRANCH" &> "$TMP_LOG_FILE"
        git checkout -b "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_BRANCH" &> "$TMP_LOG_FILE"
        empty_commits="$(check_for_empty_commits "$SECOND_REPO_REF" "$FIRST_REPO_BRANCH-rebased")"

        if [ -n "$empty_commits" ]; then
            SUCCESSFUL_REBASE_MESSAGE+="
There are empty commits:

$empty_commits

You might want to drop them."
        fi

        if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
            # Delete the temporary conflict branch on remote so there is no
            # leftovers after a success:
            delete_branch_remote "$TOKEN" "$BRANCH" "$FIRST_REPO_REMOTE_NAME"

            # Do not push to the same branch on the remote repository to avoid
            # force pushes:
            push_branch_remote "$TOKEN" "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_REMOTE_NAME"
            if ! check_for_pr "$TOKEN" "$FIRST_REPO" "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_BRANCH" ; then
                create_pr_remote "$TOKEN" "$FIRST_REPO" "$FIRST_REPO_BRANCH-rebased" "$FIRST_REPO_BRANCH" "$SUCCESSFUL_REBASE_PR_TITLE" "$SUCCESSFUL_REBASE_MESSAGE"
            fi
        else
            echo "$SUCCESSFUL_REBASE_MESSAGE"
        fi

        echo "Rebase completed successfully. No new conflicts."
        exit 0
    fi
else
    echo "ERROR: Oh no, something went wrong! The script cannot continue the rebase." >&2
    exit 3
fi

################################################################################
# Conflict handling:
################################################################################
# The strategy: never try to resolve conflicts on your own, ask a developer
# instead.
echo "Conflict detected. Inspecting rebase state..."

if [[ ! -f "$REBASE_HEAD_FILE" ]]; then
    echo "ERROR: Expected .git/REBASE_HEAD not found. Cannot determine conflicting commit." >&2
    git rebase --abort &> "$TMP_LOG_FILE"
    exit 3
fi

CONFLICT_COMMIT=$(cat "$REBASE_HEAD_FILE" 2> "$TMP_LOG_FILE")

# Build the conflict branch name: <first_repo_branch>-<hash>-conflict
CONFLICT_BRANCH="${FIRST_REPO_BRANCH}-${CONFLICT_COMMIT}-conflict"


# Create a branch at HEAD (last successfully rebased commit) before aborting to
# save the current state of the rebase. Delete the previous temporary conflict
# branch to prevent the situation that cause this script to return code 4 (see
# the usage). If the branch that was used during the rebase has the same name as
# the CONFLICT_BRANCH - it means that the conflict was either not resolved nor
# pushed to the branch after resolution by the developer. Hence, no need to
# create a branch.
if  [[ "$BRANCH" != "$CONFLICT_BRANCH" ]]; then
    git branch "$CONFLICT_BRANCH" &> "$TMP_LOG_FILE"
    if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
        push_branch_remote "$TOKEN" "$CONFLICT_BRANCH" "$FIRST_REPO_REMOTE_NAME"
    fi

    if [[ -n "$BRANCH" ]]; then
        git branch --delete "$BRANCH" &> "$TMP_LOG_FILE"
        if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
            delete_branch_remote "$TOKEN" "$BRANCH" "$FIRST_REPO_REMOTE_NAME"
        fi
    fi
fi

git rebase --abort &> "$TMP_LOG_FILE"

################################################################################
# Opening a PR/communicating via CLI with instructions on how to proceed:
################################################################################
if [[ "$LOCAL" != "true" && -n "$TOKEN" ]]; then
    first_repo_ssh="$(convert_https_to_ssh "$FIRST_REPO" )"
    first_repo_branch="$(construct_branch_url "$FIRST_REPO" "$FIRST_REPO_BRANCH" )"
    second_repo_branch="$(construct_branch_url "$SECOND_REPO" "$SECOND_REPO_BRANCH" )"
    conflict_branch="$(construct_branch_url "$FIRST_REPO" "$CONFLICT_BRANCH" )"
    message="Summary:
* First repo: $FIRST_REPO
* First repo branch: [$FIRST_REPO_BRANCH]($first_repo_branch)
* Second repo: $SECOND_REPO
* Second repo branch: [$SECOND_REPO_BRANCH]($second_repo_branch)
* Branch with the successfully rebased commits: [$CONFLICT_BRANCH]($conflict_branch)
* The commit that introduced the conflict: \`$CONFLICT_COMMIT\`

Before relaunching the automatic rebase, please do the following to solve the conflict:

1. Fetch the remote repository:

    \`\`\`
    git clone $first_repo_ssh
    \`\`\`

2. Enter the repository.
3. Checkout the conflict branch created by the script:

    \`\`\`
    git checkout $CONFLICT_BRANCH
    \`\`\`

4. Cherry-pick the commit that introduced the conflict

    \`\`\`
    git cherry-pick $CONFLICT_COMMIT
    \`\`\`

5. Solve the conflict and apply the commit after solving the conflict on top of the conflict branch. Important: if the conflict resolution resulted in an empty commit or you have decided not to resolve the conflict but to drop the commit - you must still add one commit to the \`$CONFLICT_BRANCH\` branch, even if it is an empty commit. Otherwise the automated rebase will not continue.

    \`\`\`
    git add .
    git cherry-pick --continue
    \`\`\`

6. Push the remote repository.

    \`\`\`
    git push origin $CONFLICT_BRANCH
    \`\`\`

"

    if [[ -n "$CICD_TRIGGER_RESUME" ]]; then
        message+="$CICD_TRIGGER_RESUME"
    fi

    message+="

If you want to start the automatic rebase from the beginning, then make sure to:

* Remove the \`$CONFLICT_BRANCH\` from the remote repository.
* Close this PR.
"

    unset first_repo_ssh
    unset first_repo_branch
    unset second_repo_branch
    unset conflict_branch

    pr_body="$message"
    pr_title="Automatic rebase of branch '$FIRST_REPO_BRANCH' met a conflict."

    if ! check_for_pr "$TOKEN" "$FIRST_REPO" "$CONFLICT_BRANCH" "$FIRST_REPO_BRANCH" ; then
        create_pr_remote "$TOKEN" "$FIRST_REPO" "$CONFLICT_BRANCH" "$FIRST_REPO_BRANCH" "$pr_title" "$pr_body"
    fi
else
    message="Automatic rebase of branch '$FIRST_REPO_BRANCH' met a conflict.

Summary:
* Repo                                         : $FIRST_REPO
* First branch                                 : $FIRST_REPO_BRANCH
* Second branch                                : $SECOND_REPO_BRANCH
* Branch with the successfully rebased commits : $CONFLICT_BRANCH
* The commit that introduced the conflict      : $CONFLICT_COMMIT

Before relaunching the automatic rebase, please do the following to solve the
conflict:

1. Enter the repository.
2. Checkout the conflict branch created by the script:

    git checkout $CONFLICT_BRANCH

3. Cherry-pick the commit that introduced the conflict

    git cherry-pick $CONFLICT_COMMIT

4. Solve the conflict and apply the commit after solving the conflict on top of
  the conflict branch:

    git add .
    git cherry-pick --continue

5. Try to do the rebase with this script again and wait either for a new
  conflict or for the rebase to be finished:

    $(basename "$0") $ALL_ARGS
"

    echo "$message"
fi

exit 2 
