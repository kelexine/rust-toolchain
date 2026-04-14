#!/usr/bin/env bash
# =============================================================================
# install.sh — Rust toolchain installer for air-gapped / restricted environments
# Repository: https://github.com/kelexine/rust-toolchain
# Author: kelexine <https://github.com/kelexine>
#
# Supports two execution modes:
#
#   1. Curl-pipe (no local clone required):
#        curl -sSf https://raw.githubusercontent.com/kelexine/rust-toolchain/main/install.sh | sh
#        VERSION=1.94.1 curl -sSf ... | sh   <- pin a specific version
#
#   2. Local clone:
#        git clone --depth 1 https://github.com/kelexine/rust-toolchain
#        cd rust-toolchain && ./install.sh [version]
#
# =============================================================================
# Setting BASH_ENV/ENV to empty prevents bash from sourcing them in ANY subshell
# (including command substitutions). Unsetting alone is insufficient because
# some environments re-export them. Empty string = bash skips source entirely.
export BASH_ENV=''
export ENV=''

set -euo pipefail

# -- Colours ------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# -- Constants ----------------------------------------------------------------
REPO_OWNER="kelexine"
REPO_NAME="rust-toolchain"
REPO_BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
TARGET_TRIPLE="x86_64-unknown-linux-gnu"

# -- Config -------------------------------------------------------------------
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo-toolchain}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup-toolchain}"
INSTALL_DIR="${CARGO_HOME}"
_TMPBASE="${TMPDIR:-$HOME/.tmp}"
mkdir -p "$_TMPBASE"
WORK_DIR="$(mktemp -d "$_TMPBASE/rust-toolchain-install.XXXXXX")"

# -- Cleanup on exit ----------------------------------------------------------
trap 'rm -rf "$WORK_DIR"' EXIT

# -- Mode detection -----------------------------------------------------------
# When piped via "curl | sh", BASH_SOURCE[0] is either unset, empty, or points
# to a shell binary -- never to a file containing our chunk directory. We detect
# local-clone mode by checking whether a sibling 'toolchains/' directory exists
# relative to the script's real path.
_detect_mode() {
    local script_path="${BASH_SOURCE[0]:-}"
    if [[ -n "$script_path" && "$script_path" != "bash" && "$script_path" != "sh" ]]; then
        local resolved
        resolved="$(cd "$(dirname "$script_path")" 2>/dev/null && pwd)" || true
        if [[ -n "$resolved" && -d "$resolved/toolchains" ]]; then
            INSTALL_MODE="local"
            REPO_ROOT="$resolved"
            return
        fi
    fi
    INSTALL_MODE="remote"
    REPO_ROOT=""
}

# -- Argument / version parsing -----------------------------------------------
# Priority: CLI arg $1 > env var $VERSION > resolved from stable manifest/symlink
VERSION="${1:-${VERSION:-}}"

# -- Prereqs check ------------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in cat sha256sum tar xz; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    # curl is only required in remote mode
    if [[ "$INSTALL_MODE" == "remote" ]]; then
        command -v curl &>/dev/null || missing+=("curl")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}. Install them and retry."
    fi
}

# -- Version resolution -------------------------------------------------------
resolve_version() {
    if [[ -n "$VERSION" ]]; then
        info "Version pinned: $VERSION"
        return
    fi

    if [[ "$INSTALL_MODE" == "local" ]]; then
        # Follow local 'stable' symlink
        local stable_link="$REPO_ROOT/stable"
        if [[ -L "$stable_link" ]]; then
            VERSION="$(basename "$(readlink -f "$stable_link")")"
            info "Resolved stable (local symlink) -> $VERSION"
        else
            error "No version specified and no 'stable' symlink found. Usage: $0 [version]"
        fi
    else
        # Fetch the stable manifest from GitHub raw to discover current stable version.
        info "Fetching stable version from remote..."
        local manifest_url="${RAW_BASE}/stable/manifest.json"
        local raw_manifest
        raw_manifest="$(curl -fsSL "$manifest_url")" \
            || error "Failed to fetch stable manifest from: $manifest_url"
        VERSION="$(echo "$raw_manifest" | grep -oP '"version"\s*:\s*"\K[^"]+')" \
            || error "Could not parse version from stable manifest."
        info "Resolved stable (remote manifest) -> $VERSION"
    fi
}

# -- Manifest loading ---------------------------------------------------------
load_manifest() {
    local manifest_content=""

    if [[ "$INSTALL_MODE" == "local" ]]; then
        local manifest_path="$REPO_ROOT/toolchains/$VERSION/manifest.json"
        [[ -f "$manifest_path" ]] \
            || error "Manifest not found for version $VERSION: $manifest_path"
        manifest_content="$(cat "$manifest_path")"
    else
        local manifest_url="${RAW_BASE}/toolchains/${VERSION}/manifest.json"
        info "Fetching manifest for $VERSION..."
        manifest_content="$(curl -fsSL "$manifest_url")" \
            || error "Failed to fetch manifest from: $manifest_url"
    fi

    MANIFEST_VERSION="$(echo "$manifest_content" | grep -oP '"version"\s*:\s*"\K[^"]+')"
    MANIFEST_CHUNKS="$(echo "$manifest_content"  | grep -oP '"chunks"\s*:\s*\K[0-9]+')"
    MANIFEST_SHA256="$(echo "$manifest_content"  | grep -oP '"sha256"\s*:\s*"\K[^"]+')"
    MANIFEST_DATE="$(echo "$manifest_content"    | grep -oP '"date"\s*:\s*"\K[^"]+')"

    [[ -n "$MANIFEST_VERSION" && -n "$MANIFEST_CHUNKS" && -n "$MANIFEST_SHA256" ]] \
        || error "Manifest is malformed or missing required fields."

    info "Toolchain:  Rust $MANIFEST_VERSION ($MANIFEST_DATE)"
    info "Target:     $TARGET_TRIPLE"
    info "Chunks:     $MANIFEST_CHUNKS"
}

# -- Already installed check --------------------------------------------------
check_existing() {
    local rustc_bin="$CARGO_HOME/bin/rustc"
    if [[ -x "$rustc_bin" ]]; then
        local existing_ver
        existing_ver="$("$rustc_bin" --version 2>/dev/null || true)"
        if [[ "$existing_ver" == *"$VERSION"* ]]; then
            warn "Rust $VERSION is already installed at $CARGO_HOME."
            # Non-interactive environments (curl | sh) skip the prompt.
            # Honour REINSTALL=1 env var to force reinstall without a tty.
            if [[ "${REINSTALL:-0}" == "1" ]]; then
                warn "REINSTALL=1 set -- proceeding with reinstall."
            elif [[ -t 0 ]]; then
                read -rp "Reinstall? [y/N] " reply
                [[ "${reply,,}" == "y" ]] || { info "Aborted."; exit 0; }
            else
                info "Non-interactive mode -- skipping reinstall. Set REINSTALL=1 to force."
                exit 0
            fi
        fi
    fi
}

# -- Chunk download (remote mode) ---------------------------------------------
# Downloads each chunk sequentially from raw.githubusercontent.com.
# Integrity is enforced by SHA-256 verification after reassembly -- transport
# reliability is handled by curl's --retry logic.
download_chunks() {
    local archive_name="rust-${VERSION}.tar.xz"
    local out="$WORK_DIR/$archive_name"

    info "Downloading $MANIFEST_CHUNKS chunk(s) from GitHub..."

    local i=0
    local chunk_name chunk_url
    while [[ $i -lt $MANIFEST_CHUNKS ]]; do
        chunk_name="$(printf "rust-%s.tar.xz.part%03d" "$VERSION" "$i")"
        chunk_url="${RAW_BASE}/toolchains/${VERSION}/${chunk_name}"

        info "  Chunk $((i+1))/$MANIFEST_CHUNKS: $chunk_name"
        curl -fSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-connrefused \
            --progress-bar \
            "$chunk_url" >> "$out" \
            || error "Failed to download chunk: $chunk_url"

        i=$(( i + 1 ))
    done

    success "Download complete: $archive_name ($(du -sh "$out" | cut -f1))"
    ASSEMBLED_ARCHIVE="$out"
}

# -- Chunk reassembly (local mode) --------------------------------------------
reassemble_local() {
    local toolchain_dir="$REPO_ROOT/toolchains/$VERSION"
    local archive_name="rust-${VERSION}.tar.xz"
    local out="$WORK_DIR/$archive_name"

    info "Reassembling $MANIFEST_CHUNKS chunk(s) from local repo..."

    local i=0
    local chunk
    while [[ $i -lt $MANIFEST_CHUNKS ]]; do
        chunk="$(printf "%s/rust-%s.tar.xz.part%03d" "$toolchain_dir" "$VERSION" "$i")"
        [[ -f "$chunk" ]] || error "Missing chunk: $chunk"
        cat "$chunk" >> "$out"
        i=$(( i + 1 ))
    done

    success "Reassembled: $archive_name ($(du -sh "$out" | cut -f1))"
    ASSEMBLED_ARCHIVE="$out"
}

# -- Acquire archive (dispatcher) ---------------------------------------------
acquire_archive() {
    if [[ "$INSTALL_MODE" == "remote" ]]; then
        download_chunks
    else
        reassemble_local
    fi
}

# -- Integrity verification ---------------------------------------------------
verify_integrity() {
    info "Verifying SHA-256 integrity..."
    local actual
    actual="$(sha256sum "$ASSEMBLED_ARCHIVE" | awk '{print $1}')"
    if [[ "$actual" != "$MANIFEST_SHA256" ]]; then
        error "Integrity check FAILED!\n  Expected: $MANIFEST_SHA256\n  Got:      $actual"
    fi
    success "Integrity verified."
}

# -- Extraction & installation ------------------------------------------------
install_toolchain() {
    local extract_dir="$WORK_DIR/extracted"
    mkdir -p "$extract_dir"

    info "Extracting toolchain (this may take a moment)..."
    tar -xJf "$ASSEMBLED_ARCHIVE" -C "$extract_dir"

    # Official Rust dist tarballs ship with an inner install.sh
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
        rsync -a "$extract_dir/" "$CARGO_HOME/" 2>/dev/null \
            || cp -r "$extract_dir"/. "$CARGO_HOME/"
    fi
}

# -- PATH / env setup ---------------------------------------------------------
configure_env() {
    info "Configuring environment..."

    local env_file="$CARGO_HOME/env"
    cat > "$env_file" <<EOF
# Rust toolchain environment -- generated by install.sh
# github.com/kelexine/rust-toolchain
export CARGO_HOME="$CARGO_HOME"
export RUSTUP_HOME="$RUSTUP_HOME"
export PATH="$CARGO_HOME/bin:\$PATH"
EOF

    # Source for current session
    # shellcheck source=/dev/null
    source "$env_file"

    # Append hook to shell rc files if not already present
    local marker="# rust-toolchain managed"
    local snippet="source \"$env_file\" $marker"

    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc" ]] && ! grep -qF "$marker" "$rc"; then
            { echo ""; echo "$snippet"; } >> "$rc"
            info "Added env hook to $rc"
        fi
    done
}

# -- Smoke test ---------------------------------------------------------------
smoke_test() {
    info "Running smoke test..."
    local rustc_bin="$CARGO_HOME/bin/rustc"
    local cargo_bin="$CARGO_HOME/bin/cargo"

    [[ -x "$rustc_bin" ]] || error "rustc not found at $rustc_bin"
    [[ -x "$cargo_bin" ]] || error "cargo not found at $cargo_bin"

    success "rustc:  $("$rustc_bin" --version)"
    success "cargo:  $("$cargo_bin" --version)"
}

# -- Main ---------------------------------------------------------------------
main() {
    echo -e "\n${BOLD}================================================================${RESET}"
    echo -e "${BOLD}  Rust Toolchain Installer${RESET}"
    echo -e "  github.com/kelexine/rust-toolchain"
    echo -e "${BOLD}================================================================${RESET}\n"

    _detect_mode
    info "Mode: $INSTALL_MODE"

    check_deps
    resolve_version
    load_manifest
    check_existing
    acquire_archive
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
