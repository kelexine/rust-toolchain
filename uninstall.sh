#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — Remove installed Rust toolchain
# Author: kelexine <https://github.com/kelexine>
# =============================================================================
# Prevent child bash processes from re-sourcing system shellrc (BASH_ENV).
unset BASH_ENV ENV

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

if [[ -d "$CARGO_HOME" ]];  then rm -rf "$CARGO_HOME";  success "Removed $CARGO_HOME"; fi
if [[ -d "$RUSTUP_HOME" ]]; then rm -rf "$RUSTUP_HOME"; success "Removed $RUSTUP_HOME"; fi

# Remove env hooks from shell configs
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [[ -f "$rc" ]] && grep -q "$MARKER" "$rc"; then
        sed -i "/$MARKER/d" "$rc"
        sed -i '/^source.*cargo-toolchain\/env/d' "$rc"
        info "Cleaned $rc"
    fi
done

success "Uninstall complete."
