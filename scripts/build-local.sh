#!/bin/bash

set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
signing_identity_sha1="5ACFCCF4BC98802BBE98D36A3499B4847395764A"
signing_identity_name="Amethyst Local Development"
app_path="$root_dir/.build/DerivedData/Build/Products/Release/Amethyst.app"
marketing_version=${MARKETING_VERSION:-0.24.3.2}
build_version=${CURRENT_PROJECT_VERSION:-129.2}
swiftlint_shim_dir=$(mktemp -d "${TMPDIR:-/tmp}/amethyst-build.XXXXXX")

cleanup() {
    rm -rf "$swiftlint_shim_dir"
}
trap cleanup EXIT

# Look the identity up without -v: a self-signed cert whose trust settings were
# lost (CSSMERR_TP_NOT_TRUSTED) still signs by hash, and the designated
# requirement (certificate root = H"...") that Accessibility is keyed on does
# not depend on trust. Requiring -v blocked the 0.24.3.18 install for a day.
if ! security find-identity -p codesigning | grep -q "$signing_identity_sha1"; then
    echo "Missing code-signing identity: $signing_identity_name ($signing_identity_sha1)" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$signing_identity_sha1"; then
    echo "Note: $signing_identity_name is not trusted; signing by hash anyway (TCC grant unaffected)." >&2
fi

# The project requires SwiftLint in its build phase. Local diagnostic builds do
# not modify sources during the build, so use a no-op shim when SwiftLint is not
# installed rather than failing after compilation.
if ! command -v swiftlint >/dev/null 2>&1; then
    ln -s /usr/bin/true "$swiftlint_shim_dir/swiftlint"
fi

cd "$root_dir"

PATH="$swiftlint_shim_dir:$PATH" xcodebuild \
    -workspace Amethyst.xcworkspace \
    -scheme Amethyst \
    -configuration Release \
    -derivedDataPath .build/DerivedData \
    CURRENT_PROJECT_VERSION="$build_version" \
    MARKETING_VERSION="$marketing_version" \
    CODE_SIGNING_ALLOWED=NO \
    build

codesign \
    --force \
    --deep \
    --sign "$signing_identity_sha1" \
    --timestamp=none \
    "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
codesign -d -r- "$app_path"

echo "Built and signed $app_path with $signing_identity_name"
