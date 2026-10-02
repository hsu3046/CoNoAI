#!/usr/bin/env bash
# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
# 기존 Debug ORT 산출물로 독립 CLI를 빌드한다. 다운로드/패키지 설치/앱 빌드는 하지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" -gt 2 ]]; then
    echo "Usage: $0 [local-audio-file [expected-text]]" >&2
    exit 1
fi

alignment_products="$PWD/build/Build/Products/Debug"
alignment_modulemap="$PWD/build/Build/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap"
if [[ ! -f "$alignment_products/OnnxRuntimeBindings.o" || ! -f "$alignment_modulemap" ]]; then
    echo "기존 Debug 앱 빌드의 OnnxRuntimeBindings 산출물이 필요합니다." >&2
    exit 1
fi
alignment_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cono-alignment-check.XXXXXX")
trap 'rm -rf "$alignment_tmp"' EXIT

swiftc -O -swift-version 6 -parse-as-library \
    -Xcc "-fmodule-map-file=$alignment_modulemap" \
    -F "$alignment_products" -framework onnxruntime -lc++ \
    -Xlinker -rpath -Xlinker "$alignment_products" \
    "$alignment_products/OnnxRuntimeBindings.o" \
    CoNo/Lyrics/Core/LRCParser.swift CoNo/Lyrics/Core/CTCAlignment.swift \
    CoNo/Separation/OnnxRuntimeEnvironment.swift CoNo/Separation/OmniASRCTC.swift \
    scripts/verify-alignment-model.swift -o "$alignment_tmp/verify-alignment-model"

if [[ "$#" -gt 0 ]]; then
    # 사용자가 지정한 20초 이하 파일. 정답 원문을 별도로 주면 강제 정렬도 검사하며 텍스트는 출력하지 않는다.
    /usr/bin/time -l "$alignment_tmp/verify-alignment-model" "$PWD/Models/OmniASR-CTC-300M" "$@"
else
    alignment_text="The sun is shining. We sing together and follow the music."
    /usr/bin/say -v Samantha -r 150 -o "$alignment_tmp/synthetic-speech.aiff" "$alignment_text"
    /usr/bin/time -l "$alignment_tmp/verify-alignment-model" "$PWD/Models/OmniASR-CTC-300M" \
        "$alignment_tmp/synthetic-speech.aiff" "$alignment_text"
fi
