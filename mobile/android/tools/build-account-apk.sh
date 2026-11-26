#!/usr/bin/env bash
# macOS and Linux counterpart of build-account-apk.ps1.
# Builds the Rust libraries and Android bridge with RustFerry, packages Google Play
# services with the Android Gradle plugin, and signs the APK with the local RustFerry
# signing identity.
#
# Usage: tools/build-account-apk.sh
# Overrides: CARGO_FERRY, GRADLE, ANDROID_BUILD_TOOLS, FERRY_IDENTITY_DIR
set -euo pipefail

cargo_ferry=${CARGO_FERRY:-cargo-ferry}
gradle=${GRADLE:-gradle}

mobile=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[[ -n $sdk ]] || { echo 'Set ANDROID_HOME to the Android SDK.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required to read RustFerry JSON output.' >&2; exit 1; }

tools=${ANDROID_BUILD_TOOLS:-$sdk/build-tools/36.0.0}
if [[ ! -x $tools/apksigner ]]; then
    # Fall back to the newest installed Build Tools 36.x.
    tools=$(ls -d "$sdk"/build-tools/36.* 2>/dev/null | sort -V | tail -n 1)
    [[ -n $tools && -x $tools/apksigner ]] || { echo 'Install Android Build Tools 36.' >&2; exit 1; }
fi
signer=$tools/apksigner
aapt=$tools/aapt2
align=$tools/zipalign
inputs=$mobile/target/google-play
google_project=$mobile/google-play

json_field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

build=$("$cargo_ferry" --json build android --release --project-dir "$mobile")
status=$(json_field "d.get('status')" <<<"$build")
[[ $status == ok ]] || { echo "RustFerry build failed. $(json_field "(d.get('error') or {}).get('message','')" <<<"$build")" >&2; exit 1; }
base=$(json_field "d['data']['artifact']" <<<"$build")

plan=$("$cargo_ferry" --json --dry-run build android --release --project-dir "$mobile")
manifest=$(json_field "next(s for s in d['data']['plan'] if s['stage']=='generate Android manifest and resources')['outputs'][0]" <<<"$plan")
generated=$(dirname "$manifest")

# AGP supplies these values from its namespace, release build type, and native packaging settings.
mkdir -p "$inputs"
sed -E \
    -e 's/[[:space:]]+package="[^"]*"//' \
    -e '/^[[:space:]]*android:(debuggable|extractNativeLibs)="[^"]*"[[:space:]]*$/d' \
    -e 's/[[:space:]]+android:(debuggable|extractNativeLibs)="[^"]*"//g' \
    "$generated/AndroidManifest.xml" >"$inputs/AndroidManifest.xml"

slint_java=$(cargo metadata --manifest-path "$mobile/Cargo.toml" --locked --filter-platform aarch64-linux-android --format-version 1 |
    json_field "__import__('os').path.join(__import__('os').path.dirname(next(p for p in d['packages'] if p['name']=='i-slint-backend-android-activity' and p['version']=='1.17.1')['manifest_path']), 'java')")

for pair in arm64-v8a:aarch64-linux-android x86_64:x86_64-linux-android; do
    abi=${pair%%:*} target=${pair#*:}
    mkdir -p "$inputs/jniLibs/$abi"
    cp "$mobile/target/$target/release/libstream_tube_android.so" "$inputs/jniLibs/$abi/"
done

badging=$("$aapt" dump badging "$base" | grep '^package:')
version_code=$(sed -E "s/.*versionCode='([0-9]+)'.*/\1/" <<<"$badging")
version_name=$(sed -E "s/.*versionName='([^']+)'.*/\1/" <<<"$badging")
[[ -n $version_code && -n $version_name ]] || { echo 'Could not read the Android version from the RustFerry APK.' >&2; exit 1; }

"$gradle" --no-daemon --project-dir "$google_project" --project-cache-dir="$inputs/gradle-cache" \
    -PferryInputs="$inputs" -PferryGenerated="$generated" -PslintJava="$slint_java" \
    -PstreamTubeVersionCode="$version_code" -PstreamTubeVersion="$version_name" assembleRelease

unsigned=$google_project/build/outputs/apk/release/StreamTube-release-unsigned.apk
[[ -f $unsigned ]] || { echo 'Missing unsigned APK.' >&2; exit 1; }
aligned=$inputs/stream-tube-aligned.apk
release=$inputs/Stream-Tube-Android-$version_name.apk
"$align" -P 16 -f 4 "$unsigned" "$aligned"

# RustFerry keeps its signing identity in the platform config directory.
if [[ -n ${FERRY_IDENTITY_DIR:-} ]]; then
    identity=$FERRY_IDENTITY_DIR
elif [[ $(uname -s) == Darwin ]]; then
    identity="$HOME/Library/Application Support/cargo-ferry/android"
else
    identity="${XDG_CONFIG_HOME:-$HOME/.config}/cargo-ferry/android"
fi
"$signer" sign --ks "$identity/debug.keystore" --ks-pass "file:$identity/debug-keystore.pass" \
    --ks-key-alias rustferrydebugkey --out "$release" "$aligned"
"$signer" verify --verbose --print-certs "$release"
"$align" -c -P 16 4 "$release"
echo "$release"
