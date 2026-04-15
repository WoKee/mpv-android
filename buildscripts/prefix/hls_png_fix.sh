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
orig = text

start = "pls->ctx->probesize = s->probesize > 0 ? s->probesize : 1024 * 4;"
tail = "            av_free(url);\n        }\n\n        seg = current_segment(pls);"

si = text.find(start)
if si < 0:
    print("hls_png_fix: probe start marker not found", file=sys.stderr)
    sys.exit(1)

ti = text.find(tail, si)
if ti < 0:
    print("hls_png_fix: probe end anchor not found", file=sys.stderr)
    sys.exit(1)

end = ti + len("            av_free(url);\n")

new_inner = """            /* HLS_PNG_FIX_FORCE_MPEGTS: force mpegts demuxer for TS disguised as PNG */
            void *iter = NULL;
            while ((in_fmt = av_demuxer_iterate(&iter)))
                if (strstr(in_fmt->name, "mpegts"))
                    break;
            if (!in_fmt)
                in_fmt = av_find_input_format("mpegts");
"""

text = text[:si] + new_inner + text[end:]

# Remove the per-playlist url pointer (do not touch struct segment's char *url field).
text, n = re.subn(
    r"(^[\t ]*const AVInputFormat \*in_fmt = NULL;\n)[\t ]*char \*url;\n",
    r"\1",
    text,
    count=1,
    flags=re.M,
)
if n != 1:
    print("hls_png_fix: could not remove playlist char *url declaration", file=sys.stderr)
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

echo "hls_png_fix: patch failed verification" >&2
exit 1
