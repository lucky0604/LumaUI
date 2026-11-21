#!/bin/bash
# Build the release archive from the TOC whitelist. macOS/Linux counterpart of package.ps1.
set -euo pipefail

usage() {
    echo "Usage: tools/package.sh [-o OUTPUT_DIR]"
    echo "Defaults to <project>/dist. Archive name comes from the TOC version."
}

project_root=$(cd "$(dirname "$0")/.." && pwd)
manifest="$project_root/LumaUI.toc"
output_dir=""

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            output_dir=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

command -v zip >/dev/null 2>&1 || { echo "zip is required to build the archive." >&2; exit 1; }
[ -f "$manifest" ] || { echo "Missing manifest: $manifest" >&2; exit 1; }

version_line=$(grep -m 1 '^## Version:' "$manifest" || true)
version=${version_line#'## Version:'}
version=${version%$'\r'}
version=${version#"${version%%[![:space:]]*}"}
version=${version%"${version##*[![:space:]]}"}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid package version: '$version'" >&2
    exit 1
fi

entries=("LumaUI.toc" "README.md" "docs/EXTENSIONS.md" "docs/IN_GAME_VALIDATION.md")
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
        ''|'#'*) continue ;;
    esac
    entries+=("${line//\\//}")
done < "$manifest"

# LumaUI's own textures are loaded by path, so they are not listed in the TOC
# but they must ship with it.
if [ -d "$project_root/Media" ]; then
    for media in "$project_root/Media"/*; do
        [ -f "$media" ] || continue
        entries+=("Media/$(basename "$media")")
    done
fi

for entry in "${entries[@]}"; do
    case "$entry" in
        /*) echo "Invalid package path: $entry" >&2; exit 1 ;;
        ..|../*|*/..|*/../*) echo "Invalid package path: $entry" >&2; exit 1 ;;
    esac
    if [ ! -f "$project_root/$entry" ]; then
        echo "Missing package file: $entry" >&2
        exit 1
    fi
done

if [ -z "$output_dir" ]; then
    output_dir="$project_root/dist"
fi
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
archive="$output_dir/LumaUI-$version.zip"

stage=$(mktemp -d "${TMPDIR:-/tmp}/luma-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
for entry in "${entries[@]}"; do
    destination="$stage/LumaUI/$entry"
    mkdir -p "$(dirname "$destination")"
    cp -p "$project_root/$entry" "$destination"
done

if [ -e "$archive" ]; then
    echo "Replacing existing archive: $archive" >&2
fi
rm -f "$archive"
(cd "$stage" && zip -q -D -X -r "$archive" LumaUI)

echo "$archive"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$archive"
elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$archive"
fi
