#!/data/data/com.termux/files/usr/bin/sh
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOLS_DIR="$APP_DIR/tools"
WHISPER_DIR="$TOOLS_DIR/whisper.cpp"
MODEL=${1:-base}

for command in git cmake make clang ffmpeg; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Missing command: %s\n' "$command" >&2
        printf 'Run: pkg install git cmake make clang ffmpeg\n' >&2
        exit 1
    }
done

mkdir -p "$TOOLS_DIR"
if [ ! -d "$WHISPER_DIR/.git" ]; then
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$WHISPER_DIR/build" --config Release -j 4
"$WHISPER_DIR/models/download-ggml-model.sh" "$MODEL"

printf 'Whisper is ready. Model: %s\n' "$MODEL"
