#!/bin/bash
# Fetch the pinned EmbeddingGemma 2 model before generating/building the app.
# Build-time only; the file is bundled as a resource, not committed to git.
# Public upstream only. Verifies size + SHA-256.
set -euo pipefail

cd "$(dirname "$0")/.."

DEST="Model/embeddinggemma-2-text-vision-440m.litertlm"
EXPECT_SIZE=387710976
EXPECT_SHA256="92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0"

HF_URL="https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/main/embeddinggemma-2-text-vision-440m.litertlm"

verify() {
  local size sha
  size=$(stat -f %z "$DEST" 2>/dev/null || echo 0)
  if [ "$size" != "$EXPECT_SIZE" ]; then
    echo "size mismatch: got $size, want $EXPECT_SIZE" >&2
    return 1
  fi
  sha=$(shasum -a 256 "$DEST" | awk '{print $1}')
  if [ "$sha" != "$EXPECT_SHA256" ]; then
    echo "sha256 mismatch: got $sha" >&2
    return 1
  fi
  return 0
}

mkdir -p Model

if [ -f "$DEST" ] && verify; then
  echo "OK: $DEST already present and verified"
  exit 0
fi

for url in "$HF_URL"; do
  echo "downloading from: $url"
  # -C - resumes a partial .part download; HF 302-redirects to CDN (-L).
  if curl -L --fail --retry 3 --retry-delay 5 -C - \
       --connect-timeout 30 -o "$DEST.part" "$url"; then
    mv "$DEST.part" "$DEST"
    if verify; then
      echo "OK: $DEST verified (size + sha256)"
      exit 0
    fi
    echo "verification failed, no verified download available" >&2
    rm -f "$DEST"
  else
    echo "download failed, no verified download available" >&2
    rm -f "$DEST.part"
  fi
done

echo "FAILED: could not fetch a verified model from upstream" >&2
exit 1
