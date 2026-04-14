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
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
orig = text

text = text.replace("        char *url;\n", "")

old_block = """        pls->ctx->probesize = s->probesize > 0 ? s->probesize : 1024 * 4;
        pls->ctx->max_analyze_duration = s->max_analyze_duration > 0 ? s->max_analyze_duration : 4 * AV_TIME_BASE;
        pls->ctx->interrupt_callback = s->interrupt_callback;
        url = av_strdup(pls->segments[0]->url);
        ret = av_probe_input_buffer(&pls->pb.pub, &in_fmt, url, NULL, 0, 0);

        for (int n = 0; n < pls->n_segments; n++)
            if (ret >= 0)
                ret = test_segment(s, in_fmt, pls, pls->segments[n]);

        if (ret < 0) {
            /* Free the ctx - it isn't initialized properly at this point,
             * so avformat_close_input shouldn't be called. If
             * avformat_open_input fails below, it frees and zeros the
             * context, so it doesn't need any special treatment like this. */
            av_log(s, AV_LOG_ERROR, "Error when loading first segment '%s'\\n", url);
            avformat_free_context(pls->ctx);
            pls->ctx = NULL;
            av_free(url);
            return ret;
        }
        av_free(url);"""

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

if old_block not in text:
    print("hls_png_fix: expected probe block not found", file=sys.stderr)
    sys.exit(1)

text = text.replace(old_block, new_block, 1)

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
