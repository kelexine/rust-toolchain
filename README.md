# rust-toolchain

> Self-hosted Rust toolchain distribution for air-gapped / restricted environments.
> Maintained by [@kelexine](https://github.com/kelexine)

## Why?

Some sandboxed environments (e.g., Claude's bash tool) have GitHub access but block
`rustup.rs` and `static.rust-lang.org`. This repo hosts chunked, versioned Rust
toolchain archives so you can get latest Rust anywhere GitHub is reachable.

## Target

- **Platform:** `x86_64-unknown-linux-gnu`
- **Current stable:** `1.94.0`

## Repo Layout

```
rust-toolchain/
├── README.md
├── install.sh              ← main entry point (run this)
├── uninstall.sh            ← clean removal
├── verify.sh               ← sha256 integrity check
├── pack.sh                 ← [local] package a toolchain for upload
├── toolchains/
│   └── 1.94.0/
│       ├── manifest.json   ← metadata: version, date, sha256, chunk count
│       ├── rust-1.94.0.tar.xz.sha256
│       ├── rust-1.94.0.tar.xz.part000
│       ├── rust-1.94.0.tar.xz.part001
│       └── ...             ← 90MB chunks (GitHub <100MB limit)
└── stable -> toolchains/1.94.0   ← symlink to current stable
```

## Usage

```bash
# Clone (shallow to save bandwidth)
git clone --depth 1 https://github.com/kelexine/rust-toolchain
cd rust-toolchain

# Install latest stable
./install.sh

# Or install a specific version
./install.sh 1.94.0

# Verify integrity without installing
./verify.sh 1.94.0

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
