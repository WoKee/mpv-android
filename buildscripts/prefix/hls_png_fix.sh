#!/bin/bash -e

# Apply FFmpeg HLS workaround for TS segments disguised as PNG.
# Usage:
#   hls_png_fix.sh [path-to-ffmpeg-source]

target_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deps/ffmpeg}"
target_file="$target_dir/libavformat/hls.c"

if [ ! -f "$target_file" ]; then
	echo "hls_png_fix: ffmpeg hls.c not found at: $target_file" >&2
	exit 1
fi

if grep -q "HLS_PNG_FIX_FORCE_MPEGTS" "$target_file"; then
	echo "hls_png_fix: already applied"
	exit 0
fi

python3 - "$target_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("\r\n", "\n")
orig = text

inject_after_probe = re.compile(
    r"(^[ \t]*ret\s*=\s*av_probe_input_buffer\(&pls->pb\.pub,\s*&in_fmt,\s*url,\s*NULL,\s*0,\s*0\);\s*\n)",
    flags=re.M,
)

injected_block = (
    "            /* HLS_PNG_FIX_FORCE_MPEGTS: force mpegts demuxer for TS disguised as PNG */\n"
    "            if (ret < 0)\n"
    "                ret = 0;\n"
    "            void *iter = NULL;\n"
    "            while ((in_fmt = av_demuxer_iterate(&iter)))\n"
    "                if (strstr(in_fmt->name, \"mpegts\"))\n"
    "                    break;\n"
    "            if (!in_fmt)\n"
    "                in_fmt = av_find_input_format(\"mpegts\");\n"
)

text, n = inject_after_probe.subn(r"\1" + injected_block, text, count=1)
if n != 1:
    print("hls_png_fix: probe line not found", file=sys.stderr)
    sys.exit(1)

if text == orig:
    print("hls_png_fix: no changes made", file=sys.stderr)
    sys.exit(1)

if "HLS_PNG_FIX_FORCE_MPEGTS" not in text:
    print("hls_png_fix: verification failed", file=sys.stderr)
    sys.exit(1)

path.write_text(text, encoding="utf-8")
print("hls_png_fix: patch applied")
PY

if grep -q "HLS_PNG_FIX_FORCE_MPEGTS" "$target_file"; then
	exit 0
fi

echo "hls_png_fix: patch skipped or not applicable" >&2
exit 1
