#!/bin/bash -e

# Apply FFmpeg HLS workaround for TS segments disguised as PNG.
# Usage:
#   hls_png_fix.sh [path-to-ffmpeg-source]
#
# Build-time logs go to stderr with prefix [hls_png_fix].
# Runtime logs use both AV_LOG_VERBOSE and AV_LOG_WARNING for visibility.

log() {
	printf '[hls_png_fix] %s\n' "$1" >&2
}

target_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deps/ffmpeg}"
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

log "running python rewrite..."

python3 - "$target_file" <<'PY'
import re
import sys
from pathlib import Path


def log(msg: str) -> None:
    print(f"[hls_png_fix] {msg}", file=sys.stderr)


path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("\r\n", "\n")
orig = text
log(f"read {path} ({len(text)} chars)")

inject_after_probe = re.compile(
    r"(^[ \t]*ret\s*=\s*av_probe_input_buffer\(&pls->pb\.pub,\s*&in_fmt,\s*url,\s*NULL,\s*0,\s*0\);\s*\n)",
    flags=re.M,
)

m = inject_after_probe.search(text)
if m:
    snippet = m.group(1).replace("\n", "\\n")
    log(f"regex matched probe line at offset {m.start()}: {snippet[:120]}...")
else:
    log("ERROR: regex did not match av_probe_input_buffer line")

# Note: this workaround does NOT strip PNG bytes from segments; it forces the MPEG-TS
# demuxer after libavformat's probe step so PNG-disguised TS can be opened as mpegts.
injected_block = (
    "            /* HLS_PNG_FIX_FORCE_MPEGTS: force mpegts demuxer for TS disguised as PNG */\n"
    "            av_log(s, AV_LOG_WARNING, \"HLS_PNG_FIX_HIT: forcing mpegts after probe ret=%d\\n\", ret);\n"
    "            av_log(s, AV_LOG_VERBOSE, \"HLS_PNG_FIX: after av_probe_input_buffer ret=%d, "
    "forcing mpegts demuxer (no PNG header stripping)\\n\", ret);\n"
    "            if (ret < 0)\n"
    "                ret = 0;\n"
    "            void *iter = NULL;\n"
    "            while ((in_fmt = av_demuxer_iterate(&iter)))\n"
    "                if (strstr(in_fmt->name, \"mpegts\"))\n"
    "                    break;\n"
    "            if (!in_fmt)\n"
    "                in_fmt = av_find_input_format(\"mpegts\");\n"
    "            av_log(s, AV_LOG_WARNING, \"HLS_PNG_FIX_HIT: selected sub-demuxer '%s'\\n\",\n"
    "                 in_fmt && in_fmt->name ? in_fmt->name : \"(null)\");\n"
    "            av_log(s, AV_LOG_VERBOSE, \"HLS_PNG_FIX: selected sub-demuxer '%s'\\n\",\n"
    "                 in_fmt && in_fmt->name ? in_fmt->name : \"(null)\");\n"
)

text, n = inject_after_probe.subn(r"\1" + injected_block, text, count=1)
if n != 1:
    log("ERROR: probe line not found or multiple ambiguous matches")
    sys.exit(1)

log(f"substitution count={n}, bytes delta={len(text) - len(orig)}")

if text == orig:
    log("ERROR: no changes made after substitution")
    sys.exit(1)

if "HLS_PNG_FIX_FORCE_MPEGTS" not in text:
    log("ERROR: marker missing after patch")
    sys.exit(1)

path.write_text(text, encoding="utf-8")
log("wrote patched hls.c OK")
PY

log "python finished exit=$?"

if grep -q "HLS_PNG_FIX_FORCE_MPEGTS" "$target_file"; then
	log "verified marker in file on disk"
	exit 0
fi

log "ERROR: marker missing after python (unexpected)"
exit 1
