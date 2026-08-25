#!/usr/bin/env bash
# Builds whisper.cpp and downloads a model so СОЗВОН can re-transcribe finished
# recordings locally. Everything lands outside the repo, in Application Support.
set -euo pipefail

WHISPER_ROOT="${WHISPER_ROOT:-$HOME/Library/Application Support/SOZVON/whisper}"
SRC_DIR="${WHISPER_SRC:-$WHISPER_ROOT/src}"
BIN_DIR="$WHISPER_ROOT/bin"
MODEL_DIR="$WHISPER_ROOT/models"
MODEL_NAME="${WHISPER_MODEL:-large-v3-turbo-q5_0}"
REPO_URL="https://github.com/ggml-org/whisper.cpp.git"

for tool in git cmake; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Нужен $tool. Установите его и повторите." >&2
        exit 1
    fi
done

mkdir -p "$BIN_DIR" "$MODEL_DIR"

if [[ -d "$SRC_DIR/.git" ]]; then
    echo "==> Использую существующий чекаут: $SRC_DIR"
else
    echo "==> Клонирую whisper.cpp в $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth 1 "$REPO_URL" "$SRC_DIR"
fi

echo "==> Собираю whisper-cli (статически, с Metal)"
cmake -S "$SRC_DIR" -B "$SRC_DIR/build-sozvon" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    >/dev/null

cmake --build "$SRC_DIR/build-sozvon" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"

CLI_PATH="$(find "$SRC_DIR/build-sozvon" -name whisper-cli -type f -perm -u+x | head -n 1)"

if [[ -z "$CLI_PATH" ]]; then
    echo "Не нашёл собранный whisper-cli" >&2
    exit 1
fi

cp "$CLI_PATH" "$BIN_DIR/whisper-cli"
chmod +x "$BIN_DIR/whisper-cli"
echo "==> Бинарник: $BIN_DIR/whisper-cli"

if [[ -f "$MODEL_DIR/ggml-$MODEL_NAME.bin" ]]; then
    echo "==> Модель уже на месте: ggml-$MODEL_NAME.bin"
else
    echo "==> Качаю модель $MODEL_NAME"
    (cd "$SRC_DIR" && ./models/download-ggml-model.sh "$MODEL_NAME" "$MODEL_DIR")
fi

if [[ -f "$MODEL_DIR/ggml-silero-v5.1.2.bin" ]]; then
    echo "==> VAD-модель уже на месте"
else
    echo "==> Качаю VAD-модель (убирает галлюцинации на тишине)"
    (cd "$SRC_DIR" && ./models/download-vad-model.sh silero-v5.1.2 "$MODEL_DIR")
fi

echo
echo "Готово. Whisper настроен:"
echo "  $BIN_DIR/whisper-cli"
ls -1 "$MODEL_DIR"/*.bin | sed 's/^/  /'
