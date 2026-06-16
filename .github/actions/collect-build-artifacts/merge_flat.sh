#!/usr/bin/env bash
# Merge per-artifact staging trees (from download-artifact with merge-multiple: false)
# into a single flat directory. Sequential copies avoid concurrent writes to the same
# basename, which can corrupt binaries (e.g. wheels) when merge-multiple: true is used.
#
# Usage: merge_flat.sh <staging_dir> <output_dir>
# Env: STRICT_DUPLICATE_BASENAMES=true (default) — exit 1 if two files map to the same basename.

set -euo pipefail

STAGING="${1:?usage: merge_flat.sh <staging_dir> <output_dir>}"
OUT="${2:?usage: merge_flat.sh <staging_dir> <output_dir>}"

if [[ ! -d $STAGING ]]; then
    echo "collect merge: staging directory not found: $STAGING" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

file_count=0
while IFS= read -r -d '' f; do
    base=$(basename "$f")
    dest="$OUT/$base"
    if [[ -e $dest ]]; then
        echo "collect merge: duplicate basename (refuse to overwrite). Use unique filenames across matrix artifacts." >&2
        echo "  already: $dest" >&2
        echo "  also:    $f" >&2
        exit 1
    fi
    cp -p "$f" "$dest"
    file_count=$((file_count + 1))
done < <(find "$STAGING" -type f -print0)

if [[ $file_count -eq 0 ]]; then
    echo "collect merge: no files under $STAGING (check artifact pattern and upstream uploads)" >&2
    exit 1
fi

echo "collect merge: copied $file_count file(s) into $OUT" >&2
