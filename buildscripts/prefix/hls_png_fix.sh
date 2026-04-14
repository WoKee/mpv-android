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

new_block = """        /* HLS_PNG_FIX_FORCE_MPEGTS:
         * Some HLS providers prepend a fake PNG header before TS payload.
         * For these non-standard streams, probing may pick image2/png.
         * Force MPEG-TS demuxer as a compatibility workaround.
         */
        void *iter = NULL;
        while ((in_fmt = av_demuxer_iterate(&iter)))
            if (strstr(in_fmt->name, "mpegts"))
                break;
        if (!in_fmt)
            in_fmt = av_find_input_format("mpegts");"""

text = re.sub(r"^\s*char \*url;\n", "", text, count=1, flags=re.M)

pattern = re.compile(
    r"""(?ms)
^\s*pls->ctx->probesize = s->probesize > 0 \? s->probesize : 1024 \* 4;\n
^\s*pls->ctx->max_analyze_duration = s->max_analyze_duration > 0 \? s->max_analyze_duration : 4 \* AV_TIME_BASE;\n
^\s*pls->ctx->interrupt_callback = s->interrupt_callback;\n
^\s*url = av_strdup\(pls->segments\[0\]->url\);\n
^\s*ret = av_probe_input_buffer\(&pls->pb\.pub, &in_fmt, url, NULL, 0, 0\);\n
\n
^\s*for \(int n = 0; n < pls->n_segments; n\+\+\)\n
^\s*if \(ret >= 0\)\n
^\s*ret = test_segment\(s, in_fmt, pls, pls->segments\[n\]\);\n
\n
^\s*if \(ret < 0\) \{\n
^\s*/\* Free the ctx - it isn't initialized properly at this point,\n
^\s*\* so avformat_close_input shouldn't be called\. If\n
^\s*\* avformat_open_input fails below, it frees and zeros the\n
^\s*\* context, so it doesn't need any special treatment like this\. \*/\n
^\s*av_log\(s, AV_LOG_ERROR, "Error when loading first segment '%s'\\n", url\);\n
^\s*avformat_free_context\(pls->ctx\);\n
^\s*pls->ctx = NULL;\n
^\s*av_free\(url\);\n
^\s*return ret;\n
^\s*\}\n
^\s*av_free\(url\);""",
)

text, replaced = pattern.subn(new_block, text, count=1)
if replaced != 1:
    fallback_old = "        ret = av_probe_input_buffer(&pls->pb.pub, &in_fmt, url, NULL, 0, 0);"
    fallback_new = """        ret = av_probe_input_buffer(&pls->pb.pub, &in_fmt, url, NULL, 0, 0);
        /* HLS_PNG_FIX_FORCE_MPEGTS:
         * Fallback for minor upstream hls.c layout differences.
         */
        if (ret < 0)
            ret = 0;
        void *iter = NULL;
        while ((in_fmt = av_demuxer_iterate(&iter)))
            if (strstr(in_fmt->name, "mpegts"))
                break;
        if (!in_fmt)
            in_fmt = av_find_input_format("mpegts");"""
    text = text.replace(fallback_old, fallback_new, 1)

if text == orig:
    print("hls_png_fix: no changes made", file=sys.stderr)
    sys.exit(1)

path.write_text(text, encoding="utf-8")
print("hls_png_fix: patch applied")
PY

if grep -q "HLS_PNG_FIX_FORCE_MPEGTS" "$target_file"; then
	exit 0
fi

echo "hls_png_fix: patch failed verification" >&2
exit 1
