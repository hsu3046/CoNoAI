# Third-Party Notices

## AudioCap
- Source: https://github.com/insidegui/AudioCap (commit 6f609e8)
- Used in: `CoNo/Audio/CoreAudioUtils.swift` (adapted), `CoNo/Audio/ProcessTapSession.swift` (tap/aggregate configuration referenced)

```
Copyright (c) 2024 Guilherme Rambo

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## python-audio-separator
- Source: https://github.com/nomadkaraoke/python-audio-separator (commit bf1164a), MIT License, Copyright (c) 2023 karaokenerds
- Used in: `CoNo/Separation/MDXSeparator.swift`, `CoNo/DSP/STFT.swift` — MDX 전처리·후처리 순서와 STFT 규칙을 참고해 Swift 로 재구현 (코드 복사 아님)

## ONNX Runtime
- Source: https://github.com/microsoft/onnxruntime-swift-package-manager (1.24.2), MIT License, Copyright (c) Microsoft Corporation
- Used as: Swift Package 의존성

## UVR-MDX-NET Karaoke 2 (모델 가중치)
- Source: https://github.com/TRvlvr/model_repo (Ultimate Vocal Remover 공개 모델)
- 저장소에 포함하지 않으며 `scripts/fetch-models.sh` 로 받는다. **가중치 라이선스가 명시돼 있지 않아 재배포 전 확인 필요.**

## SwiftF0
- Source: https://github.com/lars76/swift-f0 (commit 2ed0c83), MIT License, Copyright (c) 2025-2026 Lars Nieradzik
- Used in: `CoNo/Resources/swift_f0.onnx` — 원본 `swift_f0/model.onnx` 의 pitch 출력에 Cast(float) 노드를 붙인 **수정본** (`scripts/convert_swiftf0.py`). 스트리밍 규칙(`CoNo/DSP/PitchFrameStream.swift`)은 원본 `PitchStream` 을 참고해 재구현.

## mediaremote-adapter (bundled)

- Source: https://github.com/ungive/mediaremote-adapter (commit 73f14ab), vendored unmodified in `ThirdParty/mediaremote-adapter`
- License: BSD 3-Clause — full text in `ThirdParty/mediaremote-adapter/LICENSE`
- Use: built into `MediaRemoteAdapter.framework` and run by `/usr/bin/perl` to read macOS Now Playing and send play/pause to non-Music apps

## Lyrics sources (fetched at runtime, not bundled)

- **LRCLIB** — https://lrclib.net (community lyrics database)
- **AMLL TTML DB** — https://github.com/amll-dev/amll-ttml-db (CC0-1.0), community word-synced TTML lyrics
- **NetEase Cloud Music** — public web endpoints (not an official API); can be turned off in Settings › Lyrics
- **Apple Music** — optional, off by default; uses Apple's web player endpoints with the user's own subscription sign-in (not an official public API). The approach follows findings from [lyrimuse](https://github.com/Yudaotor/lyrimuse) (GPL-3.0).

