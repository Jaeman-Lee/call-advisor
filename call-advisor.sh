#!/data/data/com.termux/files/usr/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE=${CALL_ADVISOR_CONFIG:-"$APP_DIR/call-advisor.conf"}

WATCH_DIR=${WATCH_DIR:-/storage/emulated/0/Recordings/Call}
OUTPUT_DIR=${OUTPUT_DIR:-/storage/emulated/0/Recordings/CallAnalysis}
OBSIDIAN_VAULT_DIR=${OBSIDIAN_VAULT_DIR:-}
OBSIDIAN_VAULT_NAME=${OBSIDIAN_VAULT_NAME:-}
OBSIDIAN_FOLDER=${OBSIDIAN_FOLDER:-CallAnalysis}
STATE_DIR=${STATE_DIR:-"$APP_DIR/.state"}
WHISPER_DIR=${WHISPER_DIR:-"$APP_DIR/tools/whisper.cpp"}
WHISPER_BIN=${WHISPER_BIN:-"$WHISPER_DIR/build/bin/whisper-cli"}
WHISPER_MODEL=${WHISPER_MODEL:-"$WHISPER_DIR/models/ggml-base.bin"}
LANGUAGE=${LANGUAGE:-ko}
THREADS=${THREADS:-6}
STABLE_SECONDS=${STABLE_SECONDS:-3}
POLL_SECONDS=${POLL_SECONDS:-300}
WATCH_MODE=${WATCH_MODE:-auto}
EFFORT=${EFFORT:-low}
NOTIFY=${NOTIFY:-true}
SCAN_EXISTING=${SCAN_EXISTING:-false}
PROMPT=${PROMPT:-다음은 전화 통화의 자동 전사문입니다. 한국어로 핵심 요약, 합의된 내용, 해야 할 일과 담당자, 일정이나 날짜, 다시 확인할 사항을 구분하세요. 전사 오류 가능성이 있는 고유명사와 숫자는 불확실하다고 표시하세요. 추측으로 내용을 만들지 마세요.}

if [ -f "$CONFIG_FILE" ]; then
    # This is a user-owned shell configuration file.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

usage() {
    cat <<'EOF'
Usage: ./call-advisor.sh [watch|once|check]

  watch  Watch for completed call recordings (default)
  once   Scan once and exit
  check  Check paths and dependencies
EOF
}

notify() {
    [ "$NOTIFY" = true ] || return 0
    command -v termux-notification >/dev/null 2>&1 || return 0
    termux-notification --id call-advisor --title "$1" --content "$2" >/dev/null 2>&1 || true
}

notify_result() {
    result=$1
    summary=$2
    obsidian_file=${3:-}
    [ "$NOTIFY" = true ] || return 0
    command -v termux-notification >/dev/null 2>&1 || return 0
    if [ -n "$obsidian_file" ] && [ -n "$OBSIDIAN_VAULT_NAME" ] && command -v termux-open-url >/dev/null 2>&1; then
        encoded_vault=$(python -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$OBSIDIAN_VAULT_NAME")
        encoded_file=$(python -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$obsidian_file")
        action="termux-open-url 'obsidian://open?vault=$encoded_vault&file=$encoded_file'"
    else
        escaped=$(printf '%s' "$result" | sed "s/'/'\\\\''/g")
        action="termux-open '$escaped'"
    fi
    termux-notification --id call-advisor --title "통화 분석 완료" \
        --content "$summary" --priority high --action "$action" \
        --button1 "결과 열기" --button1-action "$action" >/dev/null 2>&1 || true
}

is_supported() {
    case "$1" in
        *.m4a|*.M4A|*.mp3|*.MP3|*.wav|*.WAV|*.amr|*.AMR|*.3gp|*.3GP|*.ogg|*.OGG) return 0 ;;
        *) return 1 ;;
    esac
}

fingerprint() { stat -c '%n|%s|%Y' "$1" 2>/dev/null; }

marker_path() {
    key=$(printf '%s' "$1" | cksum | awk '{print $1 "-" $2}')
    printf '%s/processed/%s' "$STATE_DIR" "$key"
}

already_done() {
    marker=$(marker_path "$1")
    [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$1" ]
}

mark_done() { printf '%s' "$1" > "$(marker_path "$1")"; }

is_stable() {
    first=$(stat -c '%s:%Y' "$1" 2>/dev/null || return 1)
    sleep "$STABLE_SECONDS"
    second=$(stat -c '%s:%Y' "$1" 2>/dev/null || return 1)
    [ "$first" = "$second" ] && [ -s "$1" ]
}

safe_stem() {
    base=${1##*/}
    stem=${base%.*}
    # Android recorder names commonly contain Korean and spaces. Preserve
    # Unicode while replacing whitespace that is awkward in result paths.
    printf '%s' "$stem" | sed 's/[[:space:]]/_/g'
}

analyze() {
    audio=$1
    fp=$(fingerprint "$audio") || return 0
    already_done "$fp" && return 0
    is_stable "$audio" || return 0

    stem=$(safe_stem "$audio")
    stamp=$(date '+%Y%m%d-%H%M%S')
    work="$STATE_DIR/work"
    wav="$work/input.wav"
    prefix="$work/transcript"
    transcript="$prefix.txt"
    result="$OUTPUT_DIR/${stem}-${stamp}.md"
    transcript_result="$OUTPUT_DIR/${stem}-${stamp}.transcript.txt"
    codex_result="$work/analysis.txt"
    whisper_metrics="$work/whisper.metrics"

    mkdir -p "$work"
    rm -f "$wav" "$transcript" "$codex_result" "$whisper_metrics"
    log "Transcribing: $audio"
    notify "통화 전사 시작" "${audio##*/}"

    total_start=$(date +%s%3N)
    audio_duration=$(env -u LD_LIBRARY_PATH ffprobe -v error \
        -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$audio" 2>/dev/null || printf 0)

    convert_start=$(date +%s%3N)
    # The Android Codex wrapper may export a bundled LD_LIBRARY_PATH that is
    # incompatible with Termux multimedia libraries. Use Termux's own loader.
    if ! env -u LD_LIBRARY_PATH ffmpeg -nostdin -v error -y -i "$audio" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$wav"; then
        log "Audio conversion failed: $audio"
        return 1
    fi
    convert_end=$(date +%s%3N)

    if ! /data/data/com.termux/files/usr/bin/time -o "$whisper_metrics" \
        -f 'user_seconds=%U\nsystem_seconds=%S\ncpu_percent=%P\nmax_rss_kb=%M\nelapsed_seconds=%e' \
        env -u LD_LIBRARY_PATH "$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$wav" -l "$LANGUAGE" \
        -t "$THREADS" -otxt -of "$prefix" -np; then
        log "Transcription failed: $audio"
        return 1
    fi

    log "Analyzing transcript with Codex"
    codex_start=$(date +%s%3N)
    if ! codex exec --ephemeral -c "model_reasoning_effort=\"$EFFORT\"" \
        --output-last-message "$codex_result" "$PROMPT" < "$transcript"; then
        log "Codex analysis failed: $audio"
        return 1
    fi
    codex_end=$(date +%s%3N)
    total_end=$(date +%s%3N)

    user_seconds=$(sed -n 's/^user_seconds=//p' "$whisper_metrics")
    system_seconds=$(sed -n 's/^system_seconds=//p' "$whisper_metrics")
    cpu_percent=$(sed -n 's/^cpu_percent=//p' "$whisper_metrics" | tr -d '%')
    max_rss_kb=$(sed -n 's/^max_rss_kb=//p' "$whisper_metrics")
    whisper_seconds=$(sed -n 's/^elapsed_seconds=//p' "$whisper_metrics")
    convert_seconds=$(awk -v a="$convert_start" -v b="$convert_end" 'BEGIN {printf "%.3f", (b-a)/1000}')
    codex_seconds=$(awk -v a="$codex_start" -v b="$codex_end" 'BEGIN {printf "%.3f", (b-a)/1000}')
    total_seconds=$(awk -v a="$total_start" -v b="$total_end" 'BEGIN {printf "%.3f", (b-a)/1000}')
    average_cores=$(awk -v p="$cpu_percent" 'BEGIN {printf "%.2f", p/100}')
    realtime_factor=$(awk -v w="$whisper_seconds" -v a="$audio_duration" 'BEGIN {if (a>0) printf "%.2f", w/a; else print "n/a"}')
    audio_per_wall=$(awk -v w="$whisper_seconds" -v a="$audio_duration" 'BEGIN {if (w>0) printf "%.2f", a/w; else print "n/a"}')
    core_seconds=$(awk -v u="$user_seconds" -v s="$system_seconds" 'BEGIN {printf "%.2f", u+s}')
    core_seconds_per_audio_min=$(awk -v u="$user_seconds" -v s="$system_seconds" -v a="$audio_duration" 'BEGIN {if (a>0) printf "%.2f", (u+s)*60/a; else print "n/a"}')
    max_rss_mb=$(awk -v k="$max_rss_kb" 'BEGIN {printf "%.1f", k/1024}')

    cp "$transcript" "$transcript_result"

    {
        printf '# 통화 분석\n\n'
        printf -- '- 원본: `%s`\n' "$audio"
        printf -- '- 분석 시각: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf -- '- 전사 언어: `%s`\n' "$LANGUAGE"
        printf -- '- reasoning effort: `%s`\n\n' "$EFFORT"
        printf '## 실행 성능\n\n'
        printf '| 지표 | 값 |\n|---|---:|\n'
        printf '| 오디오 길이 | %.2f초 |\n' "$audio_duration"
        printf '| FFmpeg 변환 | %s초 |\n' "$convert_seconds"
        printf '| Whisper wall time | %s초 |\n' "$whisper_seconds"
        printf '| Whisper 실시간 배율 | %sx |\n' "$realtime_factor"
        printf '| Whisper 처리율 | %sx realtime |\n' "$audio_per_wall"
        printf '| Whisper 평균 사용 코어 | %s개 |\n' "$average_cores"
        printf '| Whisper CPU 총시간 | %s core-seconds |\n' "$core_seconds"
        printf '| 오디오 1분당 CPU | %s core-seconds |\n' "$core_seconds_per_audio_min"
        printf '| Whisper 최대 RSS | %sMB |\n' "$max_rss_mb"
        printf '| Codex 분석 | %s초 |\n' "$codex_seconds"
        printf '| 전체 처리 | %s초 |\n\n' "$total_seconds"
        printf '## Codex 분석 결과\n\n'
        cat "$codex_result"
        printf '\n\n## 통화 전사 원문\n\n'
        cat "$transcript"
        printf '\n'
    } > "$result"

    summary=$(tr '\n' ' ' < "$codex_result" | cut -c 1-300)
    obsidian_file=
    if [ -n "$OBSIDIAN_VAULT_DIR" ]; then
        obsidian_dir="$OBSIDIAN_VAULT_DIR/$OBSIDIAN_FOLDER"
        mkdir -p "$obsidian_dir"
        cp "$result" "$obsidian_dir/${result##*/}"
        cp "$transcript_result" "$obsidian_dir/${transcript_result##*/}"
        obsidian_file="$OBSIDIAN_FOLDER/${result##*/}"
        log "Copied to Obsidian: $obsidian_file"
    fi
    mark_done "$fp"
    log "Saved: $result"
    notify_result "$result" "$summary" "$obsidian_file"
}

scan_once() {
    if [ -f "$STATE_DIR/baseline" ]; then
        find "$WATCH_DIR" -maxdepth 1 -type f -newer "$STATE_DIR/baseline" -print 2>/dev/null
    else
        find "$WATCH_DIR" -maxdepth 1 -type f -print 2>/dev/null
    fi |
    while IFS= read -r audio; do
        is_supported "$audio" || continue
        analyze "$audio" || true
    done
}

watch_events() {
    log "Using inotify events (close_write, moved_to)"
    inotifywait -q -m -e close_write -e moved_to --format '%w%f' "$WATCH_DIR" |
    while IFS= read -r audio; do
        is_supported "$audio" || continue
        analyze "$audio" || true
    done
}

initialize() {
    mkdir -p "$OUTPUT_DIR" "$STATE_DIR/processed" "$STATE_DIR/work"
    if [ ! -f "$STATE_DIR/baseline" ] && [ "$SCAN_EXISTING" != true ]; then
        touch "$STATE_DIR/baseline"
    fi
}

check_setup() {
    failed=false
    for path in "$WATCH_DIR" "$WHISPER_BIN" "$WHISPER_MODEL"; do
        if [ -e "$path" ]; then log "OK: $path"; else log "ERROR: missing $path"; failed=true; fi
    done
    for command in ffmpeg codex; do
        if command -v "$command" >/dev/null 2>&1; then log "OK: $command"; else log "ERROR: missing $command"; failed=true; fi
    done
    command -v inotifywait >/dev/null 2>&1 && log "OK: inotifywait" || log "INFO: polling fallback only"
    [ "$failed" = false ]
}

command=${1:-watch}
case "$command" in
    check) check_setup ;;
    once) initialize; scan_once ;;
    watch)
        initialize
        check_setup || exit 1
        log "Watching $WATCH_DIR (mode=$WATCH_MODE)"
        trap 'log "Stopped"; notify "통화 분석기 중지" "감시를 종료했습니다."; exit 0' INT TERM
        scan_once
        if [ "$WATCH_MODE" != poll ] && command -v inotifywait >/dev/null 2>&1; then
            watch_events
            log "inotify ended; switching to polling"
        fi
        while :; do scan_once; sleep "$POLL_SECONDS"; done
        ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
