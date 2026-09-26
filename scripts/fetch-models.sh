#!/usr/bin/env bash
# CoNo — Copyright (C) 2026 AIB Inc. — GPL-3.0-or-later
# 보컬 분리 모델을 Models/ 로 받는다 (Models/ 는 커밋하지 않는다).
# 모델: UVR-MDX-NET Karaoke 2 (github.com/TRvlvr/model_repo). 가중치 라이선스 미명시 → 배포 전 확인 필요.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Models

BASE="https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models"
MODEL="UVR_MDXNET_KARA_2.onnx"
# UVR 해시 규칙: 파일 마지막 10000 KiB 의 MD5. model_data_new.json 의 키와 대조한다.
EXPECTED_UVR_HASH="1d64a6d2c30f709b8c9b4ce1366d96ee"

if [[ ! -f "Models/$MODEL" ]]; then
    curl -fL --progress-bar "$BASE/$MODEL" -o "Models/$MODEL.part"
    mv "Models/$MODEL.part" "Models/$MODEL"
fi

actual=$(tail -c 10240000 "Models/$MODEL" | md5 -q)
if [[ "$actual" != "$EXPECTED_UVR_HASH" ]]; then
    echo "해시 불일치: $actual (기대값 $EXPECTED_UVR_HASH) — 모델 설정값이 맞지 않을 수 있습니다" >&2
    exit 1
fi
echo "OK: Models/$MODEL ($actual)"
