#!/usr/bin/env bash
# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
# 선택형 로컬 가사 학습 모델. 약 365 MB를 받으며 Models/는 Git에서 제외된다.
set -euo pipefail
cd "$(dirname "$0")/.."

alignment_dir="Models/OmniASR-CTC-300M"
alignment_revision="6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094"
alignment_base="https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/resolve/${alignment_revision}"
mkdir -p "$alignment_dir"
alignment_staging=$(mktemp -d "$alignment_dir/.download.XXXXXX")
trap 'rm -rf "$alignment_staging"' EXIT

verified_file() {
    local file_path="$1" expected_bytes="$2" expected_sha="$3"
    [[ -f "$file_path" && ! -L "$file_path" ]] &&
        [[ "$(wc -c < "$file_path" | tr -d ' ')" == "$expected_bytes" ]] &&
        [[ "$(shasum -a 256 "$file_path" | cut -d ' ' -f 1)" == "$expected_sha" ]]
}

fetch_verified() {
    local file_name="$1" expected_bytes="$2" expected_sha="$3"
    local destination="$alignment_dir/$file_name"
    local temporary="$alignment_staging/$file_name"
    if [[ -e "$destination" || -L "$destination" ]]; then
        if verified_file "$destination" "$expected_bytes" "$expected_sha"; then
            echo "OK: $destination (verified)"
            return
        fi
        echo "기존 $destination 검증 실패. 파일을 확인해 별도로 보관하거나 삭제한 뒤 다시 실행하세요." >&2
        exit 1
    fi
    echo "Downloading $file_name ($expected_bytes bytes)"
    curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 1800 \
        --retry 2 --retry-delay 2 --max-filesize "$expected_bytes" --progress-bar \
        "$alignment_base/$file_name" -o "$temporary"
    if [[ "$(wc -c < "$temporary" | tr -d ' ')" != "$expected_bytes" ]] ||
       [[ "$(shasum -a 256 "$temporary" | cut -d ' ' -f 1)" != "$expected_sha" ]]; then
        echo "$file_name 크기/SHA-256 검증 실패. 완성 모델로 설치하지 않았습니다." >&2
        exit 1
    fi
    chmod 644 "$temporary"
    # link(2)는 기존 대상(디렉터리/심볼릭 링크 포함)을 덮어쓰지 않는다.
    # ln의 '기존 디렉터리 안에 생성' 동작을 피하려 macOS의 link 유틸리티를 쓴다.
    if ! /bin/link "$temporary" "$destination" 2>/dev/null; then
        if verified_file "$destination" "$expected_bytes" "$expected_sha"; then
            echo "OK: $destination (another download installed the same verified file)"
            return
        fi
        echo "$destination 설치 충돌. 새로 생긴 기존 파일은 덮어쓰지 않았습니다." >&2
        exit 1
    fi
    echo "OK: $destination (verified)"
}

fetch_verified model.int8.onnx 365352120 e7c4e54ee4c4c47829cc6667d5d00ed8ea7bef1dcfeef0fce766f77752a2726c
fetch_verified tokens.txt 86423 a7a044c52cb29cbe8b0dc1953e92cefd4ca16b0ed968177b6beab21f9a7d0b31
fetch_verified LICENSE 581 a70a523bafbb595c2844104feb313d204904dac91c3d186c05f22a10a71c7a94
echo "로컬 정렬 모델 준비 완료 (revision $alignment_revision). 모델 가중치와 LICENSE는 Git에 넣지 않습니다."
