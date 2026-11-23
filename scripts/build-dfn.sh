#!/bin/bash
# Builds DeepFilterNet's libDF as a static library with its C API, and stages it plus the DFN3 model
# in build/dfn/. Must run once before `swift build` (the package links build/dfn/libdf.a).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=15.0
src=Engines/deepfilter/DeepFilterNet
mkdir -p build/dfn

# libDF's inference library (tract-linalg) assumes every Mac has Apple's undocumented AMX instructions.
# Newer chips (M4 and later) don't, and the engine crashes with an illegal instruction. Build against a
# copy of that crate with AMX switched off; it falls back to its standard ARM kernels.
version=$(grep -A1 'name = "tract-linalg"' "$src/Cargo.lock" | sed -n 's/version = "\(.*\)"/\1/p')
(cd "$src" && cargo fetch --quiet)
registry=$(ls -d "$HOME"/.cargo/registry/src/*/tract-linalg-"$version" | head -1)
rm -rf build/dfn/tract-linalg && cp -R "$registry" build/dfn/tract-linalg
perl -0pi -e 's/(#\[cfg\(target_os = "macos"\)\]\npub fn has_amx\(\) -> bool \{\s*)true/${1}false/' build/dfn/tract-linalg/src/arm64.rs
grep -A2 'target_os = "macos")\]' build/dfn/tract-linalg/src/arm64.rs | grep -q false || { echo "Failed to patch out AMX"; exit 1; }

(cd "$src" && cargo build --release -p deep_filter --no-default-features --features capi,default-model --lib \
  --config "patch.crates-io.tract-linalg.path=\"$PWD/../../../build/dfn/tract-linalg\"")
git -C "$src" checkout -q Cargo.lock   # cargo rewrites the lockfile; keep the submodule clean
cp "$src/target/release/libdf.a" "$src/models/DeepFilterNet3_onnx.tar.gz" build/dfn/
echo "Staged build/dfn/libdf.a and the DeepFilterNet3 model"
