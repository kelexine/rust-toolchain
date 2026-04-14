#!/usr/bin/env bash
# =============================================================================
# pack.sh — Download, chunk, and publish a Rust toolchain to kelexine/rust-toolchain
# Run this locally (not in the sandbox) where rust-lang.org is accessible.
# Author: kelexine <https://github.com/kelexine>
# =============================================================================
# Setting BASH_ENV/ENV to empty prevents bash from sourcing them in ANY subshell
# (including command substitutions). Unsetting alone is insufficient because
# some environments re-export them. Empty string = bash skips source entirely.
export BASH_ENV=''
export ENV=''

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee /dev/stderr; exit 1; }

# -- Config -------------------------------------------------------------------
VERSION="${1:-}"
TARGET="${2:-x86_64-unknown-linux-gnu}"
CHUNK_SIZE="${3:-90M}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TMPBASE="${TMPDIR:-$HOME/.tmp}"
mkdir -p "$_TMPBASE"
WORK_DIR="$(mktemp -d "$_TMPBASE/rust-pack.XXXXXX")"
RUST_DIST_BASE="https://static.rust-lang.org/dist"

trap 'rm -rf "$WORK_DIR"' EXIT

usage() {
    echo -e "Usage: $0 <version> [target] [chunk_size]"
    echo -e "  version:    Rust version, e.g. 1.94.1"
    echo -e "  target:     Default: x86_64-unknown-linux-gnu"
    echo -e "  chunk_size: Default: 90M"
    exit 1
}

if [[ -z "$VERSION" ]]; then usage; fi

# -- Prereqs ------------------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in curl sha256sum split date sed; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
    fi
}

# -- Download -----------------------------------------------------------------
download_toolchain() {
    local filename="rust-${VERSION}-${TARGET}.tar.xz"
    local sha_filename="${filename}.sha256"
    local url="$RUST_DIST_BASE/$filename"
    local sha_url="$RUST_DIST_BASE/$sha_filename"

    # Strip BASH_ENV/ENV so child processes do not re-source system shellrc
    local _curl="env -u BASH_ENV -u ENV curl"

    info "Downloading $filename..."
    $_curl -fL --progress-bar "$url" -o "$WORK_DIR/$filename" \
        || error "Download failed: $url"

    info "Downloading checksum..."
    $_curl -fsSL "$sha_url" -o "$WORK_DIR/$sha_filename" \
        || error "Checksum download failed: $sha_url"

    # Verify against upstream sha256
    info "Verifying upstream checksum..."
    local expected actual
    expected="$(awk '{print $1}' "$WORK_DIR/$sha_filename")"
    actual="$(sha256sum "$WORK_DIR/$filename" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] \
        || error "Upstream checksum mismatch!\n  Expected: $expected\n  Got:      $actual"
    success "Upstream checksum verified."

    ARCHIVE_PATH="$WORK_DIR/$filename"
    ARCHIVE_SHA256="$actual"
}

# -- Chunk --------------------------------------------------------------------
chunk_archive() {
    local out_dir="$REPO_ROOT/toolchains/$VERSION"
    mkdir -p "$out_dir"

    info "Splitting into ${CHUNK_SIZE} chunks..."
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

# -- Manifest -----------------------------------------------------------------
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

    # Standalone sha256 file (for verify.sh)
    echo "$ARCHIVE_SHA256  rust-${VERSION}.tar.xz" > "$OUT_DIR/rust-${VERSION}.tar.xz.sha256"

    MANIFEST_DATE="$release_date"
}

# -- README update ------------------------------------------------------------
# Replaces all version-specific metadata in README.md between the stable comment
# markers. Uses sed with unambiguous delimiters to handle slashes in SHA256 hashes.
update_readme() {
    local readme="$REPO_ROOT/README.md"
    [[ -f "$readme" ]] || { warn "README.md not found — skipping update."; return; }

    info "Updating README.md metadata..."

    # Build the replacement metadata block
    local chunk_label="${CHUNK_COUNT} x ${CHUNK_SIZE}"
    local new_block
    new_block="$(cat <<EOF
<!-- stable-metadata-start -->
- **Platform:** \`${TARGET}\`
- **Current stable:** \`${VERSION}\`
- **Release date:** \`${MANIFEST_DATE}\`
- **SHA-256:** \`${ARCHIVE_SHA256}\`
- **Chunks:** \`${chunk_label}\`
<!-- stable-metadata-end -->
EOF
)"

    # Replace between markers using awk (avoids sed multiline hell and
    # delimiter conflicts with slashes in SHA256 hashes).
    local tmp
    tmp="$(mktemp "$WORK_DIR/readme.XXXXXX")"

    awk -v replacement="$new_block" '
        /<!-- stable-metadata-start -->/ { in_block=1; print replacement; next }
        /<!-- stable-metadata-end -->/   { in_block=0; next }
        !in_block                        { print }
    ' "$readme" > "$tmp"

    # Also update the repo tree block between its markers
    local new_tree
    new_tree="$(cat <<EOF
<!-- repo-tree-start -->
\`\`\`
rust-toolchain/
├── README.md
├── install.sh              <- main entry point (run this)
├── uninstall.sh            <- clean removal
├── verify.sh               <- sha256 integrity check
├── pack.sh                 <- [local] package a toolchain for upload
├── toolchains/
│   └── ${VERSION}/
│       ├── manifest.json   <- metadata: version, date, sha256, chunk count
│       ├── rust-${VERSION}.tar.xz.sha256
│       ├── rust-${VERSION}.tar.xz.part000
│       ├── rust-${VERSION}.tar.xz.part001
│       └── ...             <- 90MB chunks (GitHub <100MB limit)
└── stable -> toolchains/${VERSION}   <- symlink to current stable
\`\`\`
<!-- repo-tree-end -->
EOF
)"

    awk -v replacement="$new_tree" '
        /<!-- repo-tree-start -->/ { in_block=1; print replacement; next }
        /<!-- repo-tree-end -->/   { in_block=0; next }
        !in_block                  { print }
    ' "$tmp" > "$readme"

    rm -f "$tmp"
    success "README.md updated (version=$VERSION, date=$MANIFEST_DATE, sha256=${ARCHIVE_SHA256:0:16}...)"
}

# -- Stable symlink -----------------------------------------------------------
update_stable_symlink() {
    local stable_link="$REPO_ROOT/stable"
    read -rp "Update 'stable' symlink to $VERSION? [Y/n] " reply
    if [[ "${reply,,}" != "n" ]]; then
        rm -f "$stable_link"
        ln -s "toolchains/$VERSION" "$stable_link"
        success "stable -> toolchains/$VERSION"
    fi
}

# -- Summary ------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${BOLD}================================================================${RESET}"
    echo -e "${BOLD}  Pack Summary${RESET}"
    echo -e "${BOLD}================================================================${RESET}"
    echo -e "  Version:     $VERSION"
    echo -e "  Target:      $TARGET"
    echo -e "  SHA-256:     $ARCHIVE_SHA256"
    echo -e "  Chunks:      $CHUNK_COUNT x $CHUNK_SIZE"
    echo -e "  Output:      $OUT_DIR"
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  git add toolchains/$VERSION/ stable README.md"
    echo -e "  git commit -m \"chore: add Rust $VERSION toolchain\""
    echo -e "  git push\n"
}

main() {
    echo -e "\n${BOLD}================================================================${RESET}"
    echo -e "${BOLD}  Rust Toolchain Packer${RESET}"
    echo -e "  github.com/kelexine/rust-toolchain"
    echo -e "${BOLD}================================================================${RESET}\n"

    check_deps
    download_toolchain
    chunk_archive
    write_manifest
    update_readme
    update_stable_symlink
    print_summary
}

main "$@"
