# 선택형 로컬 가사 학습 — 2026-10-03

© 2026 AIB Inc. (https://www.aib.vote) · GPL-3.0-or-later

사용자 승인 후 모델 다운로드와 로컬 추론을 연결했다. 기능은 기본으로 꺼져 있으며, AI 반주에서 분리된 보컬만 기기 안에서 분석한다. 오디오를 서버에 보내거나 파일로 저장하지 않는다. 가창 정확도는 곡마다 달라 검토용 기능으로 제공한다.

## 동작

- 자동 학습은 이미 끝난 가사 줄의 단어 시각을 분석한다. 원본 TTML/enhanced LRC의 단어 시각이 있으면 원본을 우선한다. 학습 결과는 되감기·다음 재생에 사용하며 첫 재생 전체가 즉시 정밀해진다고 표시하지 않는다.
- 최근 재생 구간에서 일반 가사에 줄·단어 시각을 붙이거나, 가사가 없으면 받아쓰기 초안을 만들 수 있다. 초안은 사용자가 확인한 뒤 로컬 저장/LRC 내보내기/줄 시간 편집에 사용한다. 생성만으로 기존 가사를 덮지 않는다.
- 기능을 켠 동안만 최근 60초 모노 보컬을 메모리에 유지한다. 한 요청은 최대 20초·512문자다. 자동 학습에는 500자 이하의 기존 가사 줄을 사용한다.
- 모델이 없거나 분석에 실패하면 기존 가사·반주·채점을 유지하고 이유를 표시한다. 기능 해제·엔진 정지 때 버퍼와 로드한 모델을 해제한다.

## 다운로드와 출처

```bash
./scripts/fetch-alignment-model.sh
```

- 모델: Meta **omniASR-CTC-300M v1**, Apache-2.0. 한국어·영어를 포함한 다국어 ASR 모델이다.
- ONNX 변환본: sherpa-onnx 유지관리자 `csukuangfj`. Meta가 직접 배포한 ONNX는 아니다.
- [sherpa-onnx 모델 문서](https://k2-fsa.github.io/sherpa/onnx/omnilingual-asr/models.html), [고정 리비전 파일 목록](https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/tree/6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094).
- 추가 pip/SPM 패키지 없이 기존 ONNX Runtime 1.24.2를 사용한다. `Models/OmniASR-CTC-300M`에 저장하고 앱 빌드 때 LICENSE와 함께 번들에 포함한다. 모델 파일은 Git에서 제외한다.
- 다운로드는 크기와 SHA-256을 검증한 파일만 설치하며, 기존 파일·디렉터리·심볼릭 링크를 덮어쓰지 않는다. 경합한 다른 다운로드의 파일이 같은 해시이면 재사용한다.

| 파일 | 바이트 | SHA-256 |
|---|---:|---|
| `model.int8.onnx` | 365,352,120 | `e7c4e54ee4c4c47829cc6667d5d00ed8ea7bef1dcfeef0fce766f77752a2726c` |
| `tokens.txt` | 86,423 | `a7a044c52cb29cbe8b0dc1953e92cefd4ca16b0ed968177b6beab21f9a7d0b31` |
| `LICENSE` | 581 | `a70a523bafbb595c2844104feb313d204904dac91c3d186c05f22a10a71c7a94` |

## 실행·저장 경계

16kHz 모노를 mean/variance(ε=1e-5)로 정규화해 `x[1,N]`에 넣고 `logits[1,T,9812]`를 받는다. blank는 0이며 Swift CTC 경로 탐색으로 원문 Character 범위와 단어 시각을 연결한다. 오디오·logits의 비유한 값, 출력 shape, 1,024프레임·1,024토큰·2,100,000 경로 셀 상한을 검사한다.

분리 워커는 보컬 버퍼만 갱신한다. 추론은 IO 콜백 밖 utility 작업에서 한 번에 하나씩, CPU 스레드 하나로 실행한다. 자동 학습 사이에는 추론 시간의 3배(최소 5초)를 쉰다. 수동 초안 편집 중 자동 작업은 쉬며 같은 실행 게이트를 공유한다.

현재 ORT 바인딩의 동기 추론은 도중에 즉시 중단하지 못한다. 취소 즉시 결과 적용·저장 권한을 철회하고, 실행 중 호출이 끝날 때까지 다음 추론을 시작하지 않는다. 모델 종료 후 취소 결과를 버린다. 곡·가사·싱크·재생 위치가 바뀐 결과도 적용하지 않는다.

학습 저장 위치는 `~/Library/Application Support/space.knowai.cono/learned-word-timings/<SHA-256>.json`이다. 버전 1, 파일당 2MiB/4,000줄 이내이고 가사 식별자·시각·신뢰도만 담는다. 모델 버전과 가사 원문·원본 시각·후보 식별자를 키에 포함한다. confidence 0.35 미만 또는 원문 일치도 0.5 미만인 결과는 저장하지 않는다. 이 값은 내부 필터이며 실제 정확도 백분율이 아니다.

손상 파일은 보존하며 오류를 표시한다. 원자 저장 전후에 취소 권한을 확인한다. 학습 기록 삭제는 저장소 세대도 바꾸므로 늦게 도착한 이전 작업이 파일을 되살리지 않는다.

## 실제 모델 검증

기존 Debug 빌드의 ONNX 연결 산출물을 재사용해 **최적화된 독립 CLI**를 실행한다. 스크립트는 앱 빌드·다운로드·패키지 설치를 하지 않는다.

```bash
# 이 경로가 verify 스크립트의 기본 산출물 경로다.
xcodebuild -project CoNo.xcodeproj -scheme CoNo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
./scripts/verify-alignment-model.sh
# 선택: 사용자가 준비한 20초 이하 파일과 해당 구간의 가사
./scripts/verify-alignment-model.sh /absolute/path/sample.wav '구간의 가사'
```

2026-10-03 현재 개발 기기에서 자체 생성 음성으로 측정했다. TTS는 노래 품질 검증을 대신하지 않는다. 아래 최대 footprint에는 모델·ORT 실행 메모리가 포함되며 앱/분리 모델의 총사용량은 별도다.

| 입력 | 처리 | 시간 | 관측 메모리 |
|---|---|---:|---:|
| 영어 TTS 3.735초 | 받아쓰기 / 강제 정렬 | 0.393 / 0.388초 | 최대 RSS 1.156GB |
| 한국어 TTS 3.955초 | 받아쓰기 / 강제 정렬 | 0.772 / 0.770초 | 최대 footprint 1.150GB |
| 자체 음성 20초 | 받아쓰기 | 5.316초 | 최대 footprint 1.370GB |

영어 강제 정렬의 내부 confidence/textMatch는 0.9154/0.9783, 한국어는 0.7082/0.8571이었다. 8/44.1/48/192kHz 합성 임펄스의 변환 길이·위치, 무음·취소 거부, 합성 CTC 경로와 Unicode 범위를 확인했다. 독립 검토의 672개 최적 경로 비교와 500개 Unicode 사례도 통과했다.

실제 곡의 반주 잔류·합창·긴 모음·빠른 랩·언어 혼합은 추가 청취 검증이 필요하다. 분석이 느리거나 재생 부하가 크면 기능을 끄고 원본 시각/탭 편집을 사용할 수 있다. 마이크를 인식하거나 목소리를 수집하는 기능은 아니다.
