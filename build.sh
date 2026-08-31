#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -n "${SYRINX_BUILD_VERSION:-}" ]; then
    version=$SYRINX_BUILD_VERSION
else
    info_plist="$repo_root/parrot/Resources/SyrinxApp/Info.plist"
    if ! version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info_plist"); then
        printf 'Could not read the app version from %s.\n' "$info_plist" >&2
        exit 1
    fi
fi
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/syrinx-build.XXXXXX")

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT HUP INT TERM

"$repo_root/scripts/release/build-app.sh" \
    --repo-root "$repo_root" \
    --swift-build \
    --unsigned-dry-run \
    --skip-source-validation \
    --version "$version" \
    --tag "v$version" \
    --output-dir "$staging_dir"

dist_dir="$repo_root/dist"
assembled_dir="$staging_dir/assembled"
dmg_source="$staging_dir/dmg-source"
dmg_name="Syrinx-$version.dmg"
staged_dmg="$staging_dir/$dmg_name"
app_path="$dist_dir/Syrinx.app"
dmg_path="$dist_dir/$dmg_name"

mkdir -p "$assembled_dir" "$dmg_source"
/usr/bin/ditto -x -k "$staging_dir/Syrinx-$version.zip" "$assembled_dir"
chmod 755 "$assembled_dir/Syrinx.app/Contents/MacOS/syrinx"
/usr/bin/codesign --force --deep --sign - "$assembled_dir/Syrinx.app"
/usr/bin/codesign --verify --deep --strict "$assembled_dir/Syrinx.app"
/usr/bin/ditto "$assembled_dir/Syrinx.app" "$dmg_source/Syrinx.app"
ln -s /Applications "$dmg_source/Applications"
/usr/bin/hdiutil create \
    -volname "Syrinx" \
    -srcfolder "$dmg_source" \
    -format UDZO \
    -ov \
    "$staged_dmg"

mkdir -p "$dist_dir"
rm -rf "$app_path"
rm -f "$dmg_path"
/usr/bin/ditto "$assembled_dir/Syrinx.app" "$app_path"
/usr/bin/ditto "$staged_dmg" "$dmg_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
test -x "$app_path/Contents/MacOS/syrinx"
/usr/bin/hdiutil verify "$dmg_path" >/dev/null
find "$dist_dir" -maxdepth 1 -type f -name 'Syrinx-*.dmg' ! -name "$dmg_name" -delete

printf 'Built %s\n' "$app_path"
printf 'Built %s\n' "$dmg_path"
