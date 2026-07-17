#!/data/data/com.termux/files/usr/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE=${CALL_ADVISOR_CONFIG:-"$APP_DIR/call-advisor.conf"}

WHISPER_DIR=${WHISPER_DIR:-"$APP_DIR/tools/whisper.cpp"}
WHISPER_BIN=${WHISPER_BIN:-"$WHISPER_DIR/build/bin/whisper-cli"}
WHISPER_MODEL=${WHISPER_MODEL:-"$WHISPER_DIR/models/ggml-base.bin"}
VAD_MODEL=${VAD_MODEL:-"$WHISPER_DIR/models/ggml-silero-v6.2.0.bin"}
LANGUAGE=${LANGUAGE:-ko}
THREAD_PROFILES=${THREAD_PROFILES:-"1 2 4 6"}

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

audio=${1:-}
if [ -z "$audio" ] || [ ! -f "$audio" ]; then
    printf 'Usage: ./benchmark-local.sh /path/to/audio.m4a\n' >&2
    exit 2
fi

work="$APP_DIR/.state/benchmark"
mkdir -p "$work"
wav="$work/input.wav"
duration=$(env -u LD_LIBRARY_PATH ffprobe -v error -show_entries format=duration \
    -of default=nokey=1:noprint_wrappers=1 "$audio")
env -u LD_LIBRARY_PATH ffmpeg -nostdin -v error -y -i "$audio" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

printf 'audio_seconds,threads,vad,wall_seconds,cpu_seconds,avg_cores,max_rss_mb,realtime_speed\n'
for threads in $THREAD_PROFILES; do
    for vad in false true; do
        metrics="$work/t${threads}-${vad}.metrics"
        vad_args=
        [ "$vad" = true ] && vad_args="--vad --vad-model $VAD_MODEL"
        /data/data/com.termux/files/usr/bin/time -o "$metrics" \
            -f 'elapsed=%e\nuser=%U\nsystem=%S\ncpu=%P\nrss=%M' \
            env -u LD_LIBRARY_PATH "$WHISPER_BIN" -m "$WHISPER_MODEL" \
            -f "$wav" -l "$LANGUAGE" -t "$threads" -np -nt $vad_args \
            >/dev/null 2>/dev/null
        elapsed=$(sed -n 's/^elapsed=//p' "$metrics")
        user=$(sed -n 's/^user=//p' "$metrics")
        system=$(sed -n 's/^system=//p' "$metrics")
        cpu=$(sed -n 's/^cpu=//p' "$metrics" | tr -d '%')
        rss=$(sed -n 's/^rss=//p' "$metrics")
        cpu_seconds=$(awk -v u="$user" -v s="$system" 'BEGIN {printf "%.2f", u+s}')
        avg_cores=$(awk -v p="$cpu" 'BEGIN {printf "%.2f", p/100}')
        rss_mb=$(awk -v k="$rss" 'BEGIN {printf "%.1f", k/1024}')
        speed=$(awk -v a="$duration" -v e="$elapsed" 'BEGIN {printf "%.2f", a/e}')
        printf '%.3f,%s,%s,%s,%s,%s,%s,%s\n' "$duration" "$threads" "$vad" \
            "$elapsed" "$cpu_seconds" "$avg_cores" "$rss_mb" "$speed"
    done
done
