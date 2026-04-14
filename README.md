# rust-toolchain

> Self-hosted Rust toolchain distribution for air-gapped / restricted environments.
> Maintained by [@kelexine](https://github.com/kelexine)

## Why?

Some sandboxed environments (e.g., Claude's Web Container Environment) have GitHub access but block
`rustup.rs` and `static.rust-lang.org`. This repo hosts chunked, versioned Rust
toolchain archives so you can get latest Rust anywhere GitHub is reachable.

## Target

<!-- stable-metadata-start -->
- **Platform:** `x86_64-unknown-linux-gnu`
- **Current stable:** `1.94.1`
- **Release date:** `2026-04-14`
- **SHA-256:** `294b3d81fa72e62581276290c60c81eb8b58498d333d422ca1dfc432877d0c40`
- **Chunks:** `3 x 90M`
<!-- stable-metadata-end -->

## Repo Layout

<!-- repo-tree-start -->
```
rust-toolchain/
├── README.md
├── install.sh              <- main entry point (run this)
├── uninstall.sh            <- clean removal
├── verify.sh               <- sha256 integrity check
├── pack.sh                 <- [local] package a toolchain for upload
├── toolchains/
│   └── 1.94.1/
│       ├── manifest.json   <- metadata: version, date, sha256, chunk count
│       ├── rust-1.94.1.tar.xz.sha256
│       ├── rust-1.94.1.tar.xz.part000
│       ├── rust-1.94.1.tar.xz.part001
│       └── ...             <- 90MB chunks (GitHub <100MB limit)
└── stable -> toolchains/1.94.1   <- symlink to current stable
```
<!-- repo-tree-end -->

## Usage

```bash
# One-liner install (no clone needed)
curl -sSf https://raw.githubusercontent.com/kelexine/rust-toolchain/main/install.sh | sh

# Pin a specific version
VERSION=1.94.1 curl -sSf https://raw.githubusercontent.com/kelexine/rust-toolchain/main/install.sh | sh

# Or clone and run locally
git clone --depth 1 https://github.com/kelexine/rust-toolchain
cd rust-toolchain

# Install latest stable
./install.sh

# Or install a specific version
./install.sh 1.94.1

# Verify integrity without installing
./verify.sh 1.94.1

# Uninstall
./uninstall.sh
```

After install, add this to your shell (install.sh does it automatically for the session):

```bash
export CARGO_HOME="$HOME/.cargo-toolchain"
export RUSTUP_HOME="$HOME/.rustup-toolchain"
export PATH="$CARGO_HOME/bin:$PATH"
```

## Adding a New Version (Maintainer Guide)

Run `pack.sh` locally with the desired version, then push the output:

```bash
./pack.sh 1.95.0
git add toolchains/1.95.0/
git commit -m "chore: add Rust 1.95.0 toolchain"
git push
# Update stable symlink
git rm stable
ln -s toolchains/1.95.0 stable
git add stable
git commit -m "chore: bump stable -> 1.95.0"
git push
```

> `pack.sh` automatically updates this README's metadata block when run.
