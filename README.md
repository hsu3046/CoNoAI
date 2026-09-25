# 🎤 CoNoAI

## Tagline-en

Your streaming app is already a karaoke machine. CoNoAI strips the vocals live and gives you a pitch bar and synced lyrics — no downloads.

## Tagline-ko

노래방 가기엔 애매한 밤, 평소 듣던 스트리밍 앱이 그대로 코노가 됩니다. 곡을 따로 받을 필요 없이 AI가 실시간으로 목소리를 지우고, 부를 음정과 가사를 흘려 줍니다. 오늘 저녁엔 방에서 한 곡 어때요?

## Tagline-ja

カラオケに行くほどでもない夜、いつもの音楽アプリがそのままカラオケボックスに。曲をダウンロードしなくても、AIがその場でボーカルを消して、歌うべき音程と歌詞を流してくれます。今夜は部屋で一曲いかがですか。

---

## Summary-en

You finally find the song you want to sing — but the karaoke version doesn't exist, or it's buried behind another app and another subscription. CoNoAI takes a different route: it listens to whatever your music app is already playing on your Mac, and a small AI model running entirely on your machine peels the lead vocal away a few seconds ahead of what you hear. That head start lets it draw the melody as a scrolling pitch bar, like a TV singing show, and light up the lyrics syllable by syllable as the singer would. Change the key when the song sits too high, and just sing.

## Summary-ko

부르고 싶은 노래는 찾았는데 반주 음원이 없거나, 있더라도 다른 앱과 다른 구독 뒤에 숨어 있을 때가 많죠. CoNoAI는 방향을 바꿨습니다. 맥에서 음악 앱이 지금 재생하는 소리를 그대로 받아, 내 컴퓨터 안에서만 도는 AI가 들리기 몇 초 전에 가수의 목소리를 걷어 냅니다. 그 몇 초의 여유 덕분에 부를 멜로디를 예능 프로그램처럼 흘러가는 음정 막대로 미리 보여 주고, 가사도 가수가 부르는 박자에 맞춰 한 음절씩 물들여 줍니다. 원래 키가 높다면 반음씩 내려서 편하게 부르면 됩니다. 곡을 내려받을 필요도, 새 서비스에 가입할 필요도 없어요.

## Summary-ja

歌いたい曲は見つかったのに、カラオケ音源がなかったり、別のアプリや別のサブスクの奥に隠れていたりしませんか。CoNoAI は発想を変えました。Mac でいつもの音楽アプリが流している音をそのまま受け取り、手元のマシンだけで動く AI が、聞こえる数秒前に歌手の声を取り除きます。その数秒の余裕で、歌うメロディーをテレビの歌番組のように流れる音程バーで先に見せ、歌詞も歌手のリズムに合わせて一音ずつ色づけていきます。キーが高ければ半音ずつ下げて、気楽に歌えばOK。曲のダウンロードも、新しいサービスへの登録もいりません。

---

## ✨ What It Does

- **Removes the lead vocal in real time** — an on-device AI model (UVR MDX-Net Karaoke) separates the singer from the band while the song plays, keeping the backing chorus.
- **Works with the app you already use** — captures the sound of Apple Music (and other music apps) directly, then mutes the original so you only hear the karaoke track.
- **Shows the melody before you sing it** — a scrolling pitch bar, drawn from the singer's actual voice, flows toward a fixed line a few seconds ahead of time.
- **Lights up lyrics syllable by syllable** — synced lyrics are fetched automatically, and the highlight follows when the singer really starts each syllable, including Japanese kanji with multi-beat readings.
- **Fixes lyrics that are out of time** — listens to the vocals to find how early or late a lyrics file is, picks the best version among several, and remembers the correction per song.
- **Changes the key** — lower or raise the backing track by up to six semitones; the pitch bar moves with it.
- **Lets you compare** — switch between karaoke, vocals only, and the original at any moment, all perfectly aligned.
- **Keeps everything on your Mac** — audio is never recorded or uploaded; only lyrics are looked up online.

---

## 🛠 Tech Stack

| Layer | Technology |
|-------|------------|
| Platform | macOS 15+ on Apple Silicon |
| Language / UI | Swift 6 (strict concurrency), SwiftUI |
| Audio capture | Core Audio process taps + private aggregate device |
| Playback | AVAudioEngine (source node + AVAudioUnitTimePitch for key change) |
| Vocal separation | UVR-MDX-NET Karaoke 2 (ONNX) via ONNX Runtime 1.24 + CoreML execution provider |
| Signal processing | Accelerate (vDSP DFT) — torch-compatible STFT, lock-free SPSC ring buffers |
| Pitch detection | SwiftF0 (ONNX) |
| Lyrics | Apple Music scripting (now playing), LRCLIB (synced lyrics), CFStringTokenizer (Japanese readings) |
| Project | XcodeGen, Swift Testing |

---

## 📦 Installation

Requirements: an Apple Silicon Mac with macOS 15 or later, Xcode 26+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/hsu3046/CoNoAI.git
cd CoNoAI
brew install xcodegen
./scripts/fetch-models.sh        # downloads the vocal separation model (~53 MB, not stored in git)
xcodegen generate
xcodebuild -project CoNo.xcodeproj -scheme CoNo -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/CoNo.app
```

- **Signing:** builds are ad-hoc signed by default, so macOS asks for permissions again after every build. To keep permissions across builds, copy `Support/Signing.local.xcconfig.example` to `Support/Signing.local.xcconfig` (git-ignored), put in your own team ID, and run `xcodegen generate` again.
- **Permissions:** on first start, allow *System Audio Recording* and, for lyrics, *Automation → Music*.
- **Use the Release build** for AI mode — the Debug build runs the signal processing about 30× slower.
- **Tip:** set your output device to 48 kHz in Audio MIDI Setup (see Known Issues).

More details: [docs/SETUP.md](docs/SETUP.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · Design decisions: [docs/DECISIONS.md](docs/DECISIONS.md)

---

## 📁 Project Structure

```
├── CoNo/
│   ├── App/                # SwiftUI screens: controls, pitch bar, karaoke lyrics
│   ├── Audio/              # Tap capture, playback engine, delay pipeline, processors, resampler
│   ├── DSP/                # STFT, streaming separator, pitch frame stream, note segmentation
│   ├── Separation/         # ONNX Runtime wrappers (MDX-Net, SwiftF0), pitch tracking
│   ├── Lyrics/             # Apple Music now playing, LRCLIB client, lyrics controller
│   │   └── Core/           # Pure logic: LRC parser, song clock, auto sync, syllable aligner
│   └── Resources/          # SwiftF0 pitch model (float output variant)
├── CoNoTests/              # Unit tests for DSP, pitch, lyrics timing
├── scripts/                # Model download, SwiftF0 conversion, click finder for diagnostics
├── docs/                   # Setup, architecture, decision log
├── project.yml             # XcodeGen project definition
└── THIRD_PARTY_NOTICES.md  # Licenses of referenced and bundled components
```

---

## ⚠️ Status & Known Issues

CoNoAI is an early proof of concept.

- Lyrics sync currently needs **Apple Music** (it provides the track and position). Other apps are captured and separated, but without lyrics.
- Occasional clicks can be heard in some sessions; a 96 kHz output device makes them more likely. Diagnostics are built in — see the issue tracker.
- The vocal separation model weights come from the Ultimate Vocal Remover project and are downloaded separately; their license is not stated, so check it before redistributing. Lyrics come from the community-run LRCLIB service.

---

## 🗺 Roadmap

- [ ] Microphone scoring with an octave-tolerant mode and a strict "one miss and you're out" mode
- [ ] Lyrics for other apps via audio fingerprinting (ShazamKit) and vocal-based sync
- [ ] Verify capture with Melon and YouTube Music
- [ ] Find and fix the intermittent click
- [ ] Optional forced-alignment model for word-perfect lyric timing
- [ ] Follow output device changes without stopping

---

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/amazing-feature`)
3. Commit your changes (`git commit -m 'feat(scope): add amazing feature'`)
4. Push to the branch (`git push origin feat/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

*Built by [KnowAI](https://knowai.space) · © 2026 KnowAI*
