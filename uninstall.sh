#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Remove installed Rust toolchain
# Author: kelexine <https://github.com/kelexine>
# =============================================================================
set -euo pipefail

YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'; BOLD='\033[1m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

CARGO_HOME="${CARGO_HOME:-$HOME/.cargo-toolchain}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup-toolchain}"
MARKER="# rust-toolchain managed"

echo -e "\n${BOLD}━━━ Rust Toolchain Uninstaller ━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
warn "This will remove $CARGO_HOME and $RUSTUP_HOME"
read -rp "Continue? [y/N] " reply
[[ "${reply,,}" == "y" ]] || { info "Aborted."; exit 0; }

[[ -d "$CARGO_HOME" ]]  && { rm -rf "$CARGO_HOME";  success "Removed $CARGO_HOME"; }
[[ -d "$RUSTUP_HOME" ]] && { rm -rf "$RUSTUP_HOME"; success "Removed $RUSTUP_HOME"; }

# Remove env hooks from shell configs
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [[ -f "$rc" ]] && grep -q "$MARKER" "$rc" && {
        # Remove the line containing the marker
        sed -i "/$MARKER/d" "$rc"
        # Also remove the source line above it (the blank line + source line)
        sed -i '/^source.*cargo-toolchain\/env/d' "$rc"
        info "Cleaned $rc"
    }
done

success "Uninstall complete."
