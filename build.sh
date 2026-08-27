#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -n "${SYRINX_BUILD_VERSION:-}" ]; then
    version=$SYRINX_BUILD_VERSION
else
    version_tag=$(git -C "$repo_root" tag --list 'v[0-9]*' --sort=-version:refname | sed -n '1p')
    if [ -z "$version_tag" ]; then
        printf 'No version tag found. Set SYRINX_BUILD_VERSION.\n' >&2
        exit 1
    fi
    version=${version_tag#v}
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

printf 'Built %s\n' "$app_path"
printf 'Built %s\n' "$dmg_path"
