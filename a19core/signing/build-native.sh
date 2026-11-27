#!/bin/bash
set -euo pipefail
ROOT="$1"
CW="$2"
PORT="$3"
UP="$RUNNER_TEMP/a19-clearsign-upstream"
test "$(git -C "$CW" rev-parse HEAD)" = "5cb0913f0c7b7608041d3eaf9cfde22f1ad58895"
python3 "$CW/Tools/verify_vendor.py" "$CW/Vendor"
rm -rf "$UP"
mkdir -p "$UP"
cp -R "$CW/Vendor/BariStore/." "$UP/"
python3 "$PORT/Native/patch_renewal_vendor.py" "$UP"
python3 "$PORT/Native/patch_bootstrap_vendor.py" "$UP"
cmp "$CW/Vendor/BariStore/src/apple/gsa.rs" "$UP/src/apple/gsa.rs"
cp "$PORT/Native/lib.rs" "$UP/src/lib.rs"
cp "$PORT/Native/setup.rs" "$UP/src/setup.rs"
printf '\n' >> "$UP/src/apple/gsa.rs"
cat "$PORT/Native/login_once.rs" >> "$UP/src/apple/gsa.rs"
printf '\n[lib]\nname = "clearsign"\npath = "src/lib.rs"\ncrate-type = ["staticlib"]\n' >> "$UP/Cargo.toml"
printf 'pub mod rppairing;\npub mod services;\npub mod session;\npub mod tcp;\npub mod tls_psk;\npub mod xpc;\n' > "$UP/src/device/mod.rs"
printf 'pub mod record;\npub mod tlv8;\npub mod opack;\npub mod host;\n' > "$UP/src/pairing/mod.rs"
mkdir -p "$ROOT/distribution/ios/a19/build" "$ROOT/src/MeloNX/MeloNX/Common/A19Signing"
cp "$UP/LICENSE" "$ROOT/src/MeloNX/MeloNX/Common/A19Signing/A19Signing-BariStore-LICENSE.txt"
cp "$UP/THIRD_PARTY_NOTICES.md" "$ROOT/src/MeloNX/MeloNX/Common/A19Signing/A19Signing-BariStore-NOTICES.txt"
rustup target add aarch64-apple-ios
(cd "$UP" && cargo test --locked --lib)
export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export IPHONEOS_DEPLOYMENT_TARGET=15.0
(cd "$UP" && cargo build --locked --release --lib --target aarch64-apple-ios)
cp "$UP/target/aarch64-apple-ios/release/libclearsign.a" "$ROOT/distribution/ios/a19/build/libclearsign.a"
lipo -verify_arch arm64 "$ROOT/distribution/ios/a19/build/libclearsign.a"
