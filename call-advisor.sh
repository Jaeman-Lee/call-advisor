#!/data/data/com.termux/files/usr/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE=${CALL_ADVISOR_CONFIG:-"$APP_DIR/call-advisor.conf"}

WATCH_DIR=${WATCH_DIR:-/storage/emulated/0/Recordings/Call}
OUTPUT_DIR=${OUTPUT_DIR:-/storage/emulated/0/Recordings/CallAnalysis}
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
    [ "$NOTIFY" = true ] || return 0
    command -v termux-notification >/dev/null 2>&1 || return 0
    escaped=$(printf '%s' "$result" | sed "s/'/'\\\\''/g")
    action="termux-open '$escaped'"
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
    codex_result="$work/analysis.txt"

    mkdir -p "$work"
    rm -f "$wav" "$transcript" "$codex_result"
    log "Transcribing: $audio"
    notify "통화 전사 시작" "${audio##*/}"

    # The Android Codex wrapper may export a bundled LD_LIBRARY_PATH that is
    # incompatible with Termux multimedia libraries. Use Termux's own loader.
    if ! env -u LD_LIBRARY_PATH ffmpeg -nostdin -v error -y -i "$audio" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$wav"; then
        log "Audio conversion failed: $audio"
        return 1
    fi

    if ! env -u LD_LIBRARY_PATH "$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$wav" -l "$LANGUAGE" \
        -t "$THREADS" -otxt -of "$prefix" -np; then
        log "Transcription failed: $audio"
        return 1
    fi

    log "Analyzing transcript with Codex"
    if ! codex exec --ephemeral -c "model_reasoning_effort=\"$EFFORT\"" \
        --output-last-message "$codex_result" "$PROMPT" < "$transcript"; then
        log "Codex analysis failed: $audio"
        return 1
    fi

    {
        printf '# 통화 분석\n\n'
        printf -- '- 원본: `%s`\n' "$audio"
        printf -- '- 분석 시각: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf -- '- 전사 언어: `%s`\n' "$LANGUAGE"
        printf -- '- reasoning effort: `%s`\n\n' "$EFFORT"
        cat "$codex_result"
        printf '\n\n## 자동 전사문\n\n'
        cat "$transcript"
        printf '\n'
    } > "$result"

    summary=$(tr '\n' ' ' < "$codex_result" | cut -c 1-300)
    mark_done "$fp"
    log "Saved: $result"
    notify_result "$result" "$summary"
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
