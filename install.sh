#!/usr/bin/env bash
# =============================================================================
# install.sh — Rust toolchain installer for air-gapped / restricted environments
# Repository: https://github.com/kelexine/rust-toolchain
# Author: kelexine <https://github.com/kelexine>
# =============================================================================
# Setting BASH_ENV to empty prevents bash from sourcing it in ANY subshell
# (including command substitutions). Unsetting alone is insufficient because
# some environments re-export it. Empty string = bash skips the source entirely.
export BASH_ENV=''
export ENV=''

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Config ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo-toolchain}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup-toolchain}"
INSTALL_DIR="${CARGO_HOME}"
WORK_DIR="$(mkdir -p "${TMPDIR:-$HOME/.tmp}" && mktemp -d "${TMPDIR:-$HOME/.tmp}/rust-toolchain-install.XXXXXX)"
TARGET_TRIPLE="x86_64-unknown-linux-gnu"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Argument parsing ─────────────────────────────────────────────────────────
VERSION="${1:-}"

resolve_version() {
    if [[ -z "$VERSION" ]]; then
        # Follow the 'stable' symlink
        local stable_link="$REPO_ROOT/stable"
        if [[ -L "$stable_link" ]]; then
            VERSION="$(basename "$(readlink -f "$stable_link")")"
            info "Resolved stable -> $VERSION"
        else
            error "No version specified and no 'stable' symlink found. Usage: $0 [version]"
        fi
    fi
}

# ── Prereqs check ────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in cat sha256sum tar xz; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}. Install them and retry."
    fi
}

# ── Manifest loading ─────────────────────────────────────────────────────────
load_manifest() {
    local manifest="$REPO_ROOT/toolchains/$VERSION/manifest.json"
    [[ -f "$manifest" ]] || error "Manifest not found for version $VERSION: $manifest"

    MANIFEST_VERSION="$(grep -oP '"version"\s*:\s*"\K[^"]+' "$manifest")"
    MANIFEST_CHUNKS="$(grep -oP '"chunks"\s*:\s*\K[0-9]+' "$manifest")"
    MANIFEST_SHA256="$(grep -oP '"sha256"\s*:\s*"\K[^"]+' "$manifest")"
    MANIFEST_DATE="$(grep -oP '"date"\s*:\s*"\K[^"]+' "$manifest")"

    info "Toolchain:  Rust $MANIFEST_VERSION ($MANIFEST_DATE)"
    info "Target:     $TARGET_TRIPLE"
    info "Chunks:     $MANIFEST_CHUNKS"
}

# ── Chunk reassembly ─────────────────────────────────────────────────────────
reassemble() {
    local toolchain_dir="$REPO_ROOT/toolchains/$VERSION"
    local archive_name="rust-${VERSION}.tar.xz"
    local out="$WORK_DIR/$archive_name"

    info "Reassembling $MANIFEST_CHUNKS chunk(s)..."

    local i=0
    while [[ $i -lt $MANIFEST_CHUNKS ]]; do
        local chunk
        chunk=$(printf "%s/rust-%s.tar.xz.part%03d" "$toolchain_dir" "$VERSION" "$i")
        [[ -f "$chunk" ]] || error "Missing chunk: $chunk"
        cat "$chunk" >> "$out"
        i=$(( i + 1 ))
    done

    success "Reassembled: $archive_name ($(du -sh "$out" | cut -f1))"
    ASSEMBLED_ARCHIVE="$out"
}

# ── Integrity verification ────────────────────────────────────────────────────
verify_integrity() {
    info "Verifying SHA-256 integrity..."
    local actual
    actual="$(sha256sum "$ASSEMBLED_ARCHIVE" | awk '{print $1}')"
    if [[ "$actual" != "$MANIFEST_SHA256" ]]; then
        error "Integrity check FAILED!\n  Expected: $MANIFEST_SHA256\n  Got:      $actual"
    fi
    success "Integrity verified."
}

# ── Extraction & installation ─────────────────────────────────────────────────
install_toolchain() {
    local extract_dir="$WORK_DIR/extracted"
    mkdir -p "$extract_dir"

    info "Extracting toolchain (this may take a moment)..."
    tar -xJf "$ASSEMBLED_ARCHIVE" -C "$extract_dir"

    # The rust-install layout has an install.sh inside
    local inner_install
    inner_install="$(find "$extract_dir" -maxdepth 2 -name "install.sh" | head -1)"

    if [[ -n "$inner_install" ]]; then
        info "Running upstream install script..."
        bash "$inner_install" \
            --prefix="$INSTALL_DIR" \
            --disable-ldconfig \
            --without=rust-docs \
            2>&1 | grep -v "^$" | sed 's/^/  /'
    else
        # Fallback: manual layout (pre-built minimal dist)
        info "Installing manually from extracted layout..."
        mkdir -p "$CARGO_HOME/bin" "$RUSTUP_HOME"
        rsync -a "$extract_dir/" "$CARGO_HOME/" 2>/dev/null || \
            cp -r "$extract_dir"/. "$CARGO_HOME/"
    fi
}

# ── PATH / env setup ──────────────────────────────────────────────────────────
configure_env() {
    info "Configuring environment..."

    # Write env snippet
    local env_file="$CARGO_HOME/env"
    cat > "$env_file" <<EOF
# Rust toolchain environment — generated by install.sh
export CARGO_HOME="$CARGO_HOME"
export RUSTUP_HOME="$RUSTUP_HOME"
export PATH="$CARGO_HOME/bin:\$PATH"
EOF

    # Source for current session
    # shellcheck source=/dev/null
    source "$env_file"

    # Append to shell configs if not already present
    local marker="# rust-toolchain managed"
    local snippet="source \"$env_file\" $marker"

    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc" ]] && ! grep -qF "$marker" "$rc"; then
            echo "" >> "$rc"
            echo "$snippet" >> "$rc"
            info "Added env hook to $rc"
        fi
    done
}

# ── Smoke test ────────────────────────────────────────────────────────────────
smoke_test() {
    info "Running smoke test..."
    local rustc_bin="$CARGO_HOME/bin/rustc"
    local cargo_bin="$CARGO_HOME/bin/cargo"

    [[ -x "$rustc_bin" ]] || error "rustc not found at $rustc_bin"
    [[ -x "$cargo_bin" ]] || error "cargo not found at $cargo_bin"

    local installed_ver
    installed_ver="$("$rustc_bin" --version)"
    success "rustc:  $installed_ver"
    success "cargo:  $("$cargo_bin" --version)"
}

# ── Already installed check ───────────────────────────────────────────────────
check_existing() {
    local rustc_bin="$CARGO_HOME/bin/rustc"
    if [[ -x "$rustc_bin" ]]; then
        local existing_ver
        existing_ver="$("$rustc_bin" --version 2>/dev/null || true)"
        if [[ "$existing_ver" == *"$VERSION"* ]]; then
            warn "Rust $VERSION is already installed at $CARGO_HOME."
            read -rp "Reinstall? [y/N] " reply
            [[ "${reply,,}" == "y" ]] || { info "Aborted."; exit 0; }
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo -e "\n${BOLD}━━━ Rust Toolchain Installer ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "    github.com/kelexine/rust-toolchain\n"

    check_deps
    resolve_version
    load_manifest
    check_existing
    reassemble
    verify_integrity
    install_toolchain
    configure_env
    smoke_test

    echo ""
    echo -e "${BOLD}${GREEN}✓ Rust $VERSION installed successfully!${RESET}"
    echo -e "  Run: ${CYAN}source \"\$HOME/.cargo-toolchain/env\"${RESET}"
    echo -e "  Or open a new shell.\n"
}

main "$@"
