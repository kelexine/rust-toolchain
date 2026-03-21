#!/usr/bin/env bash
# =============================================================================
# pack.sh — Download and chunk a Rust toolchain for upload to kelexine/rust-toolchain
# Run this locally (not in the sandbox) where rust-lang.org is accessible.
# Author: kelexine <https://github.com/kelexine>
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee /dev/stderr; exit 1; }

# ── Config ───────────────────────────────────────────────────────────────────
VERSION="${1:-}"
TARGET="${2:-x86_64-unknown-linux-gnu}"
CHUNK_SIZE="${3:-90M}"   # 90MB chunks — well under GitHub's 100MB limit
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d /tmp/rust-pack.XXXXXX)"
RUST_DIST_BASE="https://static.rust-lang.org/dist"

trap 'rm -rf "$WORK_DIR"' EXIT

usage() {
    echo -e "Usage: $0 <version> [target] [chunk_size]"
    echo -e "  version:    Rust version, e.g. 1.94.0"
    echo -e "  target:     Default: x86_64-unknown-linux-gnu"
    echo -e "  chunk_size: Default: 90M"
    exit 1
}

[[ -z "$VERSION" ]] && usage

# ── Prereqs ───────────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in curl sha256sum split date; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -gt 0 ]] && error "Missing: ${missing[*]}"
}

# ── Download ──────────────────────────────────────────────────────────────────
download_toolchain() {
    # rust distributes as: rust-VERSION-TARGET.tar.xz
    local filename="rust-${VERSION}-${TARGET}.tar.xz"
    local sha_filename="${filename}.sha256"
    local url="$RUST_DIST_BASE/$filename"
    local sha_url="$RUST_DIST_BASE/$sha_filename"

    info "Downloading $filename..."
    curl -fL --progress-bar "$url" -o "$WORK_DIR/$filename" || \
        error "Download failed: $url"

    info "Downloading checksum..."
    curl -fsSL "$sha_url" -o "$WORK_DIR/$sha_filename" || \
        error "Checksum download failed: $sha_url"

    # Verify against upstream sha256
    info "Verifying upstream checksum..."
    local expected actual
    expected="$(awk '{print $1}' "$WORK_DIR/$sha_filename")"
    actual="$(sha256sum "$WORK_DIR/$filename" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || \
        error "Upstream checksum mismatch!\n  Expected: $expected\n  Got:      $actual"
    success "Upstream checksum verified."

    ARCHIVE_PATH="$WORK_DIR/$filename"
    ARCHIVE_SHA256="$actual"
}

# ── Chunk ─────────────────────────────────────────────────────────────────────
chunk_archive() {
    local out_dir="$REPO_ROOT/toolchains/$VERSION"
    mkdir -p "$out_dir"

    info "Splitting into $CHUNK_SIZE chunks..."
    split \
        --bytes="$CHUNK_SIZE" \
        --numeric-suffixes \
        --suffix-length=3 \
        "$ARCHIVE_PATH" \
        "$out_dir/rust-${VERSION}.tar.xz.part"

    local chunk_count
    chunk_count="$(find "$out_dir" -name "rust-${VERSION}.tar.xz.part*" | wc -l)"
    success "Created $chunk_count chunks in $out_dir"

    CHUNK_COUNT="$chunk_count"
    OUT_DIR="$out_dir"
}

# ── Manifest ──────────────────────────────────────────────────────────────────
write_manifest() {
    local release_date
    release_date="$(date -u +%Y-%m-%d)"

    cat > "$OUT_DIR/manifest.json" <<EOF
{
  "version": "$VERSION",
  "target": "$TARGET",
  "date": "$release_date",
  "sha256": "$ARCHIVE_SHA256",
  "chunks": $CHUNK_COUNT,
  "chunk_size": "$CHUNK_SIZE",
  "source": "https://static.rust-lang.org/dist/rust-${VERSION}-${TARGET}.tar.xz",
  "packed_by": "kelexine/rust-toolchain pack.sh"
}
EOF
    success "Wrote manifest.json"

    # Also write standalone sha256 file
    echo "$ARCHIVE_SHA256  rust-${VERSION}.tar.xz" > "$OUT_DIR/rust-${VERSION}.tar.xz.sha256"
}

# ── Stable symlink ────────────────────────────────────────────────────────────
update_stable_symlink() {
    local stable_link="$REPO_ROOT/stable"
    read -rp "Update 'stable' symlink to $VERSION? [Y/n] " reply
    if [[ "${reply,,}" != "n" ]]; then
        rm -f "$stable_link"
        ln -s "toolchains/$VERSION" "$stable_link"
        success "stable -> toolchains/$VERSION"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}━━━ Pack Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Version:     $VERSION"
    echo -e "  Target:      $TARGET"
    echo -e "  SHA-256:     $ARCHIVE_SHA256"
    echo -e "  Chunks:      $CHUNK_COUNT × $CHUNK_SIZE"
    echo -e "  Output:      $OUT_DIR"
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  git add toolchains/$VERSION/"
    echo -e "  git add stable"
    echo -e "  git commit -m \"chore: add Rust $VERSION toolchain\""
    echo -e "  git push\n"
}

main() {
    echo -e "\n${BOLD}━━━ Rust Toolchain Packer ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "    github.com/kelexine/rust-toolchain\n"

    check_deps
    download_toolchain
    chunk_archive
    write_manifest
    update_stable_symlink
    print_summary
}

main "$@"
