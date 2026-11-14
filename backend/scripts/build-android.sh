#!/bin/bash
# Build questctl for Android (aarch64) so the Flutter app can bundle
# it and talk to the headset over Wi-Fi with the libadb direct
# transport. Run from the repo root: bash backend/scripts/build-android.sh
# Output: backend/target/aarch64-linux-android/release/questctl
# (stripped). Copy it to flutter_app/assets/questctl-android-arm64
# before `flutter build apk`.
set -e
cd "$(dirname "$0")/.."
NDK="${ANDROID_NDK_HOME:-$HOME/workspace/android-sdk/ndk/27.0.12077973}"
CLANG="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG/aarch64-linux-android34-clang"
export CC_aarch64_linux_android="$CLANG/aarch64-linux-android34-clang"
export CXX_aarch64_linux_android="$CLANG/aarch64-linux-android34-clang++"
export AR_aarch64_linux_android="$CLANG/llvm-ar"
# Same as the Linux release builds: never ship the build machine's
# absolute paths in the binary (panic locations, registry paths).
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$HOME=/build"
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --target aarch64-linux-android --release -p questctl
BIN="target/aarch64-linux-android/release/questctl"
"$CLANG/llvm-strip" "$BIN" 2>/dev/null || true
echo "built $BIN"
ls -la "$BIN"
file "$BIN"
strings "$BIN" | grep -c "/home/hatch" || true
