#!/usr/bin/env bash
# =============================================================================
# verify.sh — Verify chunk integrity without installing
# Author: kelexine <https://github.com/kelexine>
# =============================================================================
# Setting BASH_ENV to empty prevents bash from sourcing it in ANY subshell
# (including command substitutions). Unsetting alone is insufficient because
# some environments re-export it. Empty string = bash skips the source entirely.
export BASH_ENV=''
export ENV=''

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-}"
_TMPBASE="${TMPDIR:-$HOME/.tmp}"
mkdir -p "$_TMPBASE"
WORK_DIR="$(mktemp -d "$_TMPBASE/rust-verify.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -z "$VERSION" ]]; then
    stable_link="$REPO_ROOT/stable"
    if [[ -L "$stable_link" ]]; then
        VERSION="$(basename "$(readlink -f "$stable_link")")"
    else
        echo "Usage: $0 [version]"; exit 1
    fi
fi

manifest="$REPO_ROOT/toolchains/$VERSION/manifest.json"
[[ -f "$manifest" ]] || error "No manifest for $VERSION"

MANIFEST_SHA256="$(grep -oP '"sha256"\s*:\s*"\K[^"]+' "$manifest")"
MANIFEST_CHUNKS="$(grep -oP '"chunks"\s*:\s*\K[0-9]+' "$manifest")"

info "Verifying Rust $VERSION ($MANIFEST_CHUNKS chunks)..."

archive="$WORK_DIR/rust-${VERSION}.tar.xz"
i=0
while [[ $i -lt $MANIFEST_CHUNKS ]]; do
    chunk=$(printf "%s/toolchains/%s/rust-%s.tar.xz.part%03d" \
        "$REPO_ROOT" "$VERSION" "$VERSION" "$i")
    [[ -f "$chunk" ]] || error "Missing chunk: $chunk"
    cat "$chunk" >> "$archive"
    i=$(( i + 1 ))
done

actual="$(sha256sum "$archive" | awk '{print $1}')"
if [[ "$actual" == "$MANIFEST_SHA256" ]]; then
    success "SHA-256 OK: $actual"
else
    error "MISMATCH!\n  Expected: $MANIFEST_SHA256\n  Got:      $actual"
fi
