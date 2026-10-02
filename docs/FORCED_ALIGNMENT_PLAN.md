# 선택형 정밀 가사 학습 모델 검토 — 2026-10-02

© 2026 AIB Inc. (https://www.aib.vote) · GPL-3.0-or-later

## 적용할 동작

사용자가 선택하면 한 곡을 들으며 분리된 보컬과 현재 가사를 정렬하고, 완성된 줄의 단어 시각만 로컬 JSON에 저장한다. 다음 재생·되감기에는 학습한 시각을 사용한다. 첫 재생의 모든 단어가 곧바로 정확해진다고 표시하지 않는다. 기본 3.5초 지연 안에 긴 줄 전체 오디오를 확보할 수 없기 때문이다.

- 노래 오디오를 서버로 전송하거나 파일로 보관하지 않는다.
- 기존 TTML/enhanced LRC의 원본 단어 시각을 우선한다.
- 모델이 없거나 실패하면 기존 가사 표시·반주·채점이 그대로 동작한다.
- 파일 가져오기/정밀 타임스탬프 기능은 이 추가 모델 없이 이미 구현되어 있다.

## 후보와 다운로드 범위

- 모델: Meta **omniASR-CTC-300M v1**, Apache-2.0. 한국어(`kor_Hang`)·영어(`eng_Latn`) 등 다국어.
- 변환본: sherpa-onnx 유지관리자 `csukuangfj`의 int8 ONNX. Meta가 직접 배포한 ONNX가 아니므로 출처를 구분한다.
- [`sherpa-onnx 모델 문서`](https://k2-fsa.github.io/sherpa/onnx/omnilingual-asr/models.html)
- [`고정 리비전 파일 목록`](https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/tree/6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094)
- 모델 365,352,120 bytes, tokens.txt 86,423 bytes 및 Apache-2.0 LICENSE.
- 모델 SHA-256: `e7c4e54ee4c4c47829cc6667d5d00ed8ea7bef1dcfeef0fce766f77752a2726c`.
- 추가 pip/SPM 설치 없이 기존 ONNX Runtime 1.24.2를 재사용한다. 파일은 기존 Models 정책처럼 Git에서 제외한다.

## 구현 경계와 검증

16 kHz 모노 보컬을 정규화(mean/variance, epsilon 1e-5)한 `x[1,N]`을 모델에 넣고 `logits[1,T,9812]`를 받는다. blank는 0. Swift CTC 경로 탐색/역추적으로 현재 가사 문자열을 맞추고 기존 `LyricSegment`로 변환한다.

분리 워커와 별도의 단일 추론 큐를 쓰며 IO 콜백에서 모델을 호출하지 않는다. 모델 로드/실패/취소/메모리 제한, 곡 전환 세대 확인, 학습한 시각의 원자적 저장을 검증한다. 합성 CTC 테스트와 기존 노래 샘플로 타이밍·추론 시간·메모리를 측정한 뒤 사용 가능 여부를 판단한다. ASR 언어 지원이 노래 정렬 품질을 보장하지는 않는다.

현재는 모델을 내려받거나 설치하지 않았다. 추가 모델 승인 전에도 점수 공유·원본 타임스탬프·로컬 가사 가져오기·진단·안내 영상의 구현과 PR 검증은 계속한다.
