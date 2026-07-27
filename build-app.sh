#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$script_dir"
version="${OWLS_COMPANION_VERSION:-0.3.2}"
build_number="${OWLS_COMPANION_BUILD_NUMBER:-3}"
configuration="${OWLS_COMPANION_CONFIGURATION:-release}"
output_dir="$package_dir/dist"
app_path="$output_dir/owls Companion.app"

swift build \
  --package-path "$package_dir" \
  --configuration "$configuration" \
  --product OwlsCompanion

bin_dir="$(swift build \
  --package-path "$package_dir" \
  --configuration "$configuration" \
  --show-bin-path)"

rm -rf "$app_path"
mkdir -p \
  "$app_path/Contents/MacOS" \
  "$app_path/Contents/Frameworks" \
  "$app_path/Contents/Resources"

cp "$bin_dir/OwlsCompanion" "$app_path/Contents/MacOS/OwlsCompanion"
cp "$package_dir/Info.plist" "$app_path/Contents/Info.plist"

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $version" \
  "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $build_number" \
  "$app_path/Contents/Info.plist"

ditto \
  "$package_dir/Sources/OwlsCompanionApp/Resources" \
  "$app_path/Contents/Resources"
ditto \
  "$package_dir/Sources/OwlsCompanionCore/Resources" \
  "$app_path/Contents/Resources"

signing_identity="${CODESIGN_IDENTITY:--}"
codesign_arguments=(
  --force
  --deep
  --options runtime
  --sign "$signing_identity"
)
if [[ "$signing_identity" != "-" ]]; then
  codesign_arguments+=(--timestamp)
fi
codesign "${codesign_arguments[@]}" "$app_path"

echo "$app_path"
