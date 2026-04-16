#!/bin/bash -e

# Apply FFmpeg HLS workaround for TS segments disguised as PNG.
# Usage:
#   hls_png_fix.sh [path-to-ffmpeg-source]
#
# Apply a unified diff patch file (no Python dependency).
# Build-time logs go to stderr with prefix [hls_png_fix].
# Runtime logs use both AV_LOG_VERBOSE and AV_LOG_WARNING for visibility.

log() {
	printf '[hls_png_fix] %s\n' "$1" >&2
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="${1:-$(cd "$here/.." && pwd)/deps/ffmpeg}"
target_file="$target_dir/libavformat/hls.c"

log "target_dir=$target_dir"

if [ ! -f "$target_file" ]; then
	log "ERROR: hls.c not found at $target_file"
	exit 1
fi

log "hls.c present ($(wc -c <"$target_file" | tr -d ' ') bytes)"

if grep -q "HLS_PNG_FIX_FORCE_MPEGTS" "$target_file"; then
	log "marker already present, skip (idempotent)"
	exit 0
fi

if grep -q "ret = av_probe_input_buffer(&pls->pb.pub, &in_fmt, url, NULL, 0, 0)" "$target_file"; then
	log "found av_probe_input_buffer(&pls->pb.pub...) line (inject anchor OK)"
else
	log "WARN: expected av_probe_input_buffer anchor string not found verbatim; patch may still match with regex"
fi

patch_file="$here/hls_png_fix.patch"
if [ ! -f "$patch_file" ]; then
	log "ERROR: patch file not found at $patch_file"
	exit 1
fi

if ! command -v patch >/dev/null 2>&1; then
	log "ERROR: 'patch' command not found in PATH"
	exit 1
fi

log "applying patch file ($(basename "$patch_file"))..."

if ! (cd "$target_dir" && patch -p1 --forward --binary <"$patch_file"); then
	log "ERROR: patch command failed"
	exit 1
fi

if grep -q "HLS_PNG_FIX_FORCE_MPEGTS" "$target_file"; then
	log "verified marker in file on disk"
	exit 0
fi

log "ERROR: marker missing after patch apply (unexpected)"
exit 1
