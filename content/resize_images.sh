#!/usr/bin/env bash

# Resize images in-place so their longest edge does not exceed a limit.
# macOS ships with the `sips` command used by this script.

set -u

max_size=6000
dry_run=0

usage() {
  cat <<'EOF'
Usage: ./resize_images.sh [--max PIXELS] [--dry-run] [FOLDER ...]

Defaults:
  PIXELS: 6000
  FOLDER:  bella eileen diana gladys fiona

Only oversized images are changed. Images are replaced only after a resized
temporary file has been created and validated successfully.
EOF
}

folders=()
while (($#)); do
  case "$1" in
    --max)
      if (($# < 2)); then
        echo "Error: --max requires a pixel value." >&2
        exit 2
      fi
      max_size=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while (($#)); do
        folders+=("$1")
        shift
      done
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      folders+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$max_size" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --max must be a positive integer." >&2
  exit 2
fi

if ((${#folders[@]} == 0)); then
  folders=(bella eileen diana gladys fiona)
fi

for folder in "${folders[@]}"; do
  if [[ ! -d "$folder" ]]; then
    echo "Error: folder does not exist: $folder" >&2
    exit 2
  fi
done

if ! command -v sips >/dev/null 2>&1; then
  echo "Error: this script requires macOS 'sips'." >&2
  exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/resize-images.XXXXXX") || exit 1
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

scanned=0
resized=0
skipped=0
failed=0

while IFS= read -r -d '' file; do
  ((scanned += 1))

  dimensions=$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null) || {
    echo "FAILED (cannot read dimensions): $file" >&2
    ((failed += 1))
    continue
  }
  width=$(awk '/pixelWidth:/ { print $2; exit }' <<<"$dimensions")
  height=$(awk '/pixelHeight:/ { print $2; exit }' <<<"$dimensions")

  if ! [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]]; then
    echo "FAILED (invalid dimensions): $file" >&2
    ((failed += 1))
    continue
  fi

  if ((width <= max_size && height <= max_size)); then
    ((skipped += 1))
    continue
  fi

  if ((dry_run)); then
    echo "WOULD RESIZE: $file (${width}x${height})"
    ((resized += 1))
    continue
  fi

  extension=${file##*.}
  tmp_file="$tmp_dir/${scanned}.${extension}"
  if ! sips --resampleHeightWidthMax "$max_size" "$file" --out "$tmp_file" >/dev/null 2>&1; then
    echo "FAILED (resize error): $file" >&2
    ((failed += 1))
    continue
  fi

  new_dimensions=$(sips -g pixelWidth -g pixelHeight "$tmp_file" 2>/dev/null) || true
  new_width=$(awk '/pixelWidth:/ { print $2; exit }' <<<"$new_dimensions")
  new_height=$(awk '/pixelHeight:/ { print $2; exit }' <<<"$new_dimensions")
  if ! [[ "$new_width" =~ ^[0-9]+$ && "$new_height" =~ ^[0-9]+$ ]] ||
     ((new_width > max_size || new_height > max_size)); then
    echo "FAILED (output validation error): $file" >&2
    rm -f "$tmp_file"
    ((failed += 1))
    continue
  fi

  if mv -f "$tmp_file" "$file"; then
    echo "RESIZED: $file (${width}x${height} -> ${new_width}x${new_height})"
    ((resized += 1))
  else
    echo "FAILED (replace error): $file" >&2
    ((failed += 1))
  fi
done < <(
  find "${folders[@]}" -type f \( \
    -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o \
    -iname '*.tif' -o -iname '*.tiff' -o -iname '*.webp' \
  \) -print0
)

echo
echo "Done: scanned=$scanned resized=$resized unchanged=$skipped failed=$failed max=${max_size}px"
((failed == 0))
