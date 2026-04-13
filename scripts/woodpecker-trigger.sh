#!/bin/bash

# SPDX-FileCopyrightText: 2026 3mdeb <contact@3mdeb.com>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# Pinned woodpecker-cli version. Override with the WOODPECKER_CLI_VERSION
# environment variable.
# Check https://github.com/woodpecker-ci/woodpecker/releases for available
# versions.
WOODPECKER_CLI_VERSION="${WOODPECKER_CLI_VERSION:-3.13.0}"
WP_BIN=""
WP_TMPDIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger a Woodpecker CI/CD pipeline via woodpecker-cli.
The woodpecker-cli binary is downloaded automatically for the current platform.
woodpecker-cli reads WOODPECKER_SERVER and WOODPECKER_TOKEN from the
environment; no login/logout step is needed.

Requires: curl (to download woodpecker-cli), tar

Options:
  -h, --help                Show this help message and exit
  -v, --verbose             Enable verbose output (set -x).
                            Note: token value will be visible in output.
  -t, --token TOKEN         Woodpecker API token (required)
  -u, --api-url URL         Base URL of the Woodpecker instance, e.g.
                            https://ci.example.com (required)
  -o, --owner OWNER         Repository owner (user or organization) (required)
  -r, --repo REPO           Repository name (required)
      --ref REF             Branch to trigger the pipeline on (default: main)
      --input KEY=VALUE     Variable to pass to the pipeline as a KEY=VALUE
                            pair (forwarded as --var to woodpecker-cli; key
                            must be a valid shell variable name). May be
                            specified multiple times.

Environment variables:
  WOODPECKER_CLI_VERSION    woodpecker-cli version to download (default: 2.7.0)

Exit codes:
  0   Pipeline triggered successfully
  1   Error

Example:
  $(basename "$0") \\
    --token your_api_token \\
    --api-url https://ci.example.com \\
    --owner myorg \\
    --repo myrepo \\
    --ref main \\
    --input MY_VAR=value \\
    --input ANOTHER_VAR=other
EOF
}

# Removes the temporary directory containing the woodpecker-cli binary.
# Registered as an EXIT trap after the binary is downloaded.
cleanup() {
    if [[ -n "$WP_TMPDIR" ]]; then
        rm -rf "$WP_TMPDIR"
    fi
}

# Prints the OS component of the woodpecker-cli binary name (linux or darwin).
# Return codes:
# 0: Success.
# 1: Unsupported OS.
detect_os() {
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in
        linux|darwin) echo "$os" ;;
        *)
            echo "ERROR: Unsupported OS: $(uname -s)" >&2
            return 1
            ;;
    esac
}

# Prints the architecture component of the woodpecker-cli binary name.
# Return codes:
# 0: Success.
# 1: Unsupported architecture.
detect_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "arm-7" ;;
        i386|i686)     echo "386"   ;;
        *)
            echo "ERROR: Unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

# Downloads the woodpecker-cli binary for the current platform to a temporary
# directory. Sets the global WP_BIN and WP_TMPDIR variables.
# Return codes:
# 0: Success.
# 1: Download or platform detection failed.
download_woodpecker_cli() {
    local version="$1"
    local os arch filename url

    os="$(detect_os)"
    arch="$(detect_arch)"
    WP_TMPDIR="$(mktemp -d)"
    WP_BIN="${WP_TMPDIR}/woodpecker-cli"

    filename="woodpecker-cli_${os}_${arch}.tar.gz"
    url="https://github.com/woodpecker-ci/woodpecker/releases/download/v${version}/${filename}"

    echo "Downloading woodpecker-cli v${version} (${os}/${arch})..."
    curl -sL --fail -o "${WP_TMPDIR}/${filename}" "$url" || {
        echo "ERROR: Failed to download woodpecker-cli from: ${url}" >&2
        return 1
    }
    tar -xzf "${WP_TMPDIR}/${filename}" -C "$WP_TMPDIR" woodpecker-cli
    chmod +x "$WP_BIN"
}

# Configuration and initial values:
TOKEN=""
API_URL=""
OWNER=""
REPO=""
WORKFLOW=""
REF="main"
INPUTS=()

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
            -t|--token)
                TOKEN="$2"
                shift 2
                ;;
            -u|--api-url)
                API_URL="$2"
                shift 2
                ;;
            -o|--owner)
                OWNER="$2"
                shift 2
                ;;
            -r|--repo)
                REPO="$2"
                shift 2
                ;;
            -w|--workflow)
                WORKFLOW="$2"
                shift 2
                ;;
            --ref)
                REF="$2"
                shift 2
                ;;
            --input)
                INPUTS+=("$2")
                shift 2
                ;;
            -*)
                echo "ERROR: Unknown option $1" >&2
                usage
                exit 1
                ;;
            *)
                echo "ERROR: Unexpected argument '$1'" >&2
                usage
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

# Validate required parameters:
errors=0
[[ -z "$TOKEN"   ]] && { echo "ERROR: --token is required."   >&2; errors=$((errors+1)); }
[[ -z "$API_URL" ]] && { echo "ERROR: --api-url is required." >&2; errors=$((errors+1)); }
[[ -z "$OWNER"   ]] && { echo "ERROR: --owner is required."   >&2; errors=$((errors+1)); }
[[ -z "$REPO"    ]] && { echo "ERROR: --repo is required."    >&2; errors=$((errors+1)); }
if [[ $errors -gt 0 ]]; then
    usage
    exit 1
fi

# Strip trailing slash from API_URL:
API_URL="${API_URL%/}"

# Download woodpecker-cli and register cleanup on exit:
download_woodpecker_cli "$WOODPECKER_CLI_VERSION"
trap cleanup EXIT

# Build the pipeline create command.
cmd=("$WP_BIN" pipeline create "${OWNER}/${REPO}" --branch "$REF")
for var in "${INPUTS[@]}"; do
    cmd+=(--var "$var")
done

echo "Triggering pipeline for ${OWNER}/${REPO} on branch '${REF}'..."
WOODPECKER_SERVER="$API_URL" WOODPECKER_TOKEN="$TOKEN" "${cmd[@]}"

echo "Pipeline triggered successfully."
