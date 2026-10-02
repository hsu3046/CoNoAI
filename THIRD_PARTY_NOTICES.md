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

## omniASR-CTC-300M v1 (optional model)

- Model: Meta omniASR-CTC-300M v1, Apache License 2.0, Copyright 2025 (c) Meta Platforms, Inc. and affiliates.
- ONNX conversion: [csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12](https://huggingface.co/csukuangfj/sherpa-onnx-omnilingual-asr-1600-languages-300M-ctc-int8-2025-11-12/tree/6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094), pinned revision `6abf1ece20cd2308bdb7d13cd78ec1c44fa4c094`. This ONNX conversion is distributed by the sherpa-onnx maintainer, not directly by Meta.
- `scripts/fetch-alignment-model.sh` downloads the unchanged int8 model, vocabulary and upstream LICENSE into the Git-ignored `Models/OmniASR-CTC-300M` directory. When present, all three files are included in the app bundle. No recordings or external lyrics are bundled. File hashes and runtime limits: [FORCED_ALIGNMENT_PLAN.md](docs/FORCED_ALIGNMENT_PLAN.md).
- The Swift CTC decoder and integration are original CoNo code. They reuse the existing ONNX Runtime dependency.

The downloaded upstream license notice is preserved verbatim:

```text
Copyright 2025 (c) Meta Platforms, Inc. and affiliates.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## mediaremote-adapter (bundled)

- Source: https://github.com/ungive/mediaremote-adapter (commit 73f14ab), vendored unmodified in `ThirdParty/mediaremote-adapter`
- License: BSD 3-Clause — full text in `ThirdParty/mediaremote-adapter/LICENSE`
- Use: built into `MediaRemoteAdapter.framework` and run by `/usr/bin/perl` to read macOS Now Playing and send play/pause to non-Music apps

## Lyrics sources (fetched at runtime, not bundled)

- **LRCLIB** — https://lrclib.net (community lyrics database)
- **AMLL TTML DB** — https://github.com/amll-dev/amll-ttml-db (CC0-1.0), community word-synced TTML lyrics
- **NetEase Cloud Music** — public web endpoints (not an official API); can be turned off in Settings › Lyrics
- **Apple Music** — optional, off by default; uses Apple's web player endpoints with the user's own subscription sign-in (not an official public API). The approach follows findings from [lyrimuse](https://github.com/Yudaotor/lyrimuse) (GPL-3.0).

## KRC file format references

- Sources: [LyricsKit KRC decoder](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Parser/KugouKrcDecrypter.swift) and [parser](https://github.com/ddddxxx/LyricsKit/blob/master/Sources/LyricsService/Parser/KugouKrcParser.swift) (MPL-2.0), [lyrimuse Kugou implementation](https://github.com/Yudaotor/lyrimuse/blob/main/lyrimuse-collector/kugou.go) (GPL-3.0).
- Used in: `CoNo/Lyrics/Core/KRCLyrics.swift` — KRC header, fixed XOR mask, compression, and relative word timestamp format were referenced for a new Swift implementation. No upstream source files or packages are bundled. Decompression uses macOS system zlib.
- Tests contain synthetic text only; Kugou lyrics and access keys are not bundled. This supports user-selected local KRC files, not an online Kugou service connection.

## QRC decoder — QQMusicDecoder

- Source: [QQMusicDecoder](https://github.com/WXRIW/QQMusicDecoder/tree/0e1494194523dd885405812a91ee9b9702bfb30c), commit `0e1494194523dd885405812a91ee9b9702bfb30c` (`QQMusicDecoder/DESHelper.cs`, `Decrypter.cs`).
- Used in: `CoNo/Lyrics/Core/QRCLyrics.swift` — Swift adaptation of the QRC-specific DES variant, including its nonstandard S-box entries, key schedule, and byte ordering. No .NET or SharpZipLib dependency is bundled; bounded decompression uses macOS system zlib.

```text
MIT License

Copyright (c) 2023 WXRIW

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## QRC local-file XOR — qmc-decode

- Source: [qmc-decode](https://github.com/jixunmoe/qmc-decode/tree/0266189adfa135b7471fb3452f7e777f0ff210e9), commit `0266189adfa135b7471fb3452f7e777f0ff210e9` (`src/qmc_crypto.c`).
- Used in: `CoNo/Lyrics/Core/QRCLyrics.swift` — adapted fixed lookup table and byte-offset transform for user-selected local QRC files. These format constants are not service authentication credentials.

```text
MIT License

Copyright (c) 2019 Jixun Wu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## QRC independent verification reference

- Source: [LDDC](https://github.com/chenmozhijin/LDDC/tree/84631e8cd011fcc3f71ca0ae017e2c9758958ffc), commit `84631e8cd011fcc3f71ca0ae017e2c9758958ffc` (`LDDC/core/decryptor/tripledes.py`, `LDDC/core/parser/qrc.py`), GPL-3.0-only, Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>.
- Its original Python cipher functions were executed separately to generate synthetic known-answer test vectors for `CoNoTests/QRCLyricsTests.swift`; LDDC code and dependencies are not bundled. No real service lyrics, responses, or account tokens are test fixtures.


## Drum roll with cymbal crash (sound effect)
- Source: "Long Snare Drum Roll with Cymbal Crash.mp3" by MissloonerVoiceOver255 — https://freesound.org/people/MissloonerVoiceOver255/sounds/569113/
- License: Creative Commons 0 (public domain dedication) — https://creativecommons.org/publicdomain/zero/1.0/
- Used in: `CoNo/Resources/Drumroll.m4a` (trimmed to the last 2.8 s of the roll plus the crash, faded, normalized, AAC) — played with the singing score
