# 🎤 CoNoAI

## Tagline-en

Your music app is already a karaoke machine. CoNoAI strips the vocals live and adds a pitch bar and synced lyrics — no downloads.

## Tagline-ko

노래방 가기엔 애매한 밤, 평소 듣던 음악 앱이나 브라우저의 YouTube가 그대로 코노가 됩니다. 곡을 따로 받을 필요 없이 AI가 실시간으로 목소리를 지우고, 부를 음정과 가사를 흘려 줍니다. 키가 높으면 버튼 하나로 내 목소리에 맞추면 돼요.

## Tagline-ja

カラオケに行くほどでもない夜、いつもの音楽アプリやブラウザのYouTubeがそのままカラオケボックスに。曲をダウンロードしなくても、AIがその場でボーカルを消して、歌うべき音程と歌詞を流してくれます。キーが高ければボタンひとつで自分の声に合わせられます。

---

## Summary-en

You finally find the song you want to sing — but the karaoke version doesn't exist, or it's buried behind another app and another subscription. CoNoAI takes a different route: it listens to whatever is already playing on your Mac, whether that's Apple Music or a video in your browser, and a small AI model running entirely on your machine peels the lead vocal away a few seconds ahead of what you hear. That head start lets it draw the melody as a scrolling pitch bar, like a TV singing show, and light up the lyrics syllable by syllable as the singer would. Press "My key" and it moves the song to a comfortable height for your voice, then just sing.

## Summary-ko

부르고 싶은 노래는 찾았는데 반주 음원이 없거나, 있더라도 다른 앱과 다른 구독 뒤에 숨어 있을 때가 많죠. CoNoAI는 방향을 바꿨습니다. 맥에서 지금 흐르는 소리를 그대로 받아 — Apple Music이든 브라우저의 YouTube든 — 내 컴퓨터 안에서만 도는 AI가 들리기 몇 초 전에 가수의 목소리를 걷어 냅니다. 그 몇 초의 여유 덕분에 부를 멜로디를 예능 프로그램처럼 흘러가는 음정 막대로 미리 보여 주고, 가사도 가수가 부르는 박자에 맞춰 한 음절씩 물들여 줍니다. 키가 높다면 '내 키' 한 번이면 내 목소리에 편한 높이로 옮겨 줘요. 곡을 내려받을 필요도, 새 서비스에 가입할 필요도 없습니다.

## Summary-ja

歌いたい曲は見つかったのに、カラオケ音源がなかったり、別のアプリや別のサブスクの奥に隠れていたりしませんか。CoNoAI は発想を変えました。Mac でいま流れている音を — Apple Music でもブラウザの YouTube でも — そのまま受け取り、手元のマシンだけで動く AI が、聞こえる数秒前に歌手の声を取り除きます。その数秒の余裕で、歌うメロディーをテレビの歌番組のように流れる音程バーで先に見せ、歌詞も歌手のリズムに合わせて一音ずつ色づけていきます。キーが高ければ「マイキー」ひとつで自分の声に楽な高さへ。曲のダウンロードも、新しいサービスへの登録もいりません。

---

## ✨ What It Does

- **Removes the lead vocal in real time** — an on-device AI model (UVR MDX-Net Karaoke) separates the singer from the band while the song plays, keeping the backing chorus.
- **Works with the app you already use** — captures Apple Music, browsers (YouTube, YouTube Music) and other music apps directly, then mutes the original so you only hear the karaoke track.
- **Shows the melody before you sing it** — a scrolling pitch bar, drawn from the singer's actual voice, flows toward the playhead a few seconds ahead of time; auto zoom and the singer's pitch line can be toggled right on the bar.
- **Lights up lyrics syllable by syllable** — synced lyrics are fetched automatically, and the highlight follows when the singer really starts each syllable, including Japanese kanji with multi-beat readings.
- **Finds lyrics even for music videos** — video titles like "Artist - Song / THE FIRST TAKE" are cleaned up, and lyrics are re-timed to the video even when its intro is longer than the studio track.
- **Fixes lyrics that are out of time** — listens to the vocals to measure how early or late a lyrics file is, follows live versions that drift, and remembers the correction per song. You can still nudge it by hovering over the lyrics.
- **Moves the key to your voice** — step by semitone like a karaoke remote, or press "My key" to fit the song to your voice, even across genders.
- **Plays, pauses, and seeks like a karaoke machine** — pause freezes the sound, pitch bar and lyrics together and resumes without losing a beat; drag the progress bar or skip a long interlude.
- **Lets you mix a guide vocal** — blend a little of the original voice back in, or switch between karaoke, vocals only and the original at any moment.
- **Sets the stage** — album art colors light the background and breathe with the music; full screen hides the controls for TV or projector.
- **Keeps everything on your Mac** — audio is never uploaded; only lyrics are looked up online.

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
| Now playing | Apple Music scripting; macOS Now Playing via bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) for other apps |
| Lyrics | LRCLIB (synced lyrics), CFStringTokenizer (Japanese readings) |
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

- **Start singing:** play a song in Apple Music and CoNo starts on its own. For a browser or another app, press **노래 시작** (Start), or pick that app in Settings › General to have it start automatically too.
- **Permissions:** allow *Screen & System Audio Recording* on first start. For Apple Music, also allow *Automation → Music*. Settings › General lists each permission with a button that opens the right System Settings pane.
- **Signing:** builds are ad-hoc signed by default, so macOS asks for permissions again after every build. To keep permissions across builds, copy `Support/Signing.local.xcconfig.example` to `Support/Signing.local.xcconfig` (git-ignored), put in your own team ID, and run `xcodegen generate` again.
- **Use the Release build** for AI mode — the Debug build runs the signal processing about 30× slower.

**Keyboard:** Space play/pause · ↑↓ key · K my key · 0 original key · 1 2 3 karaoke / vocals / original · → skip interlude · [ ] lyrics sync · ⌘, settings

More details: [docs/SETUP.md](docs/SETUP.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · Design decisions: [docs/DECISIONS.md](docs/DECISIONS.md)

---

## 📁 Project Structure

```
├── CoNo/
│   ├── App/                # Stage screen, control dock, progress bar, pitch bar, lyrics, settings
│   ├── Audio/              # Tap capture, playback engine, delay pipeline, pause/seek, media key
│   ├── DSP/                # STFT, streaming separator, pitch frames, note segmentation, "My key"
│   ├── Separation/         # ONNX Runtime wrappers (MDX-Net, SwiftF0), pitch tracking
│   ├── Lyrics/             # Now playing (Music / other apps), LRCLIB client, lyrics controller
│   │   └── Core/           # Pure logic: LRC parser, song clock, auto sync, syllable aligner, title cleaner
│   └── Resources/          # SwiftF0 pitch model (float output variant)
├── CoNoTests/              # Unit tests for DSP, pitch, lyrics timing, selection, seek arrival
├── ThirdParty/             # mediaremote-adapter (BSD-3, vendored, built as a framework)
├── scripts/                # Model download, SwiftF0 conversion, click finder for diagnostics
├── docs/                   # Setup, architecture, decision log
├── project.yml             # XcodeGen project definition
└── THIRD_PARTY_NOTICES.md  # Licenses of referenced and bundled components
```

---

## ⚠️ Status & Known Issues

CoNoAI is an early preview.

- The pitch bar, "My key" and automatic lyrics sync need AI mode. Capturing the whole system (instead of one app) has no song info, lyrics or playback control.
- Reading "Now Playing" from other apps relies on a helper that macOS may block in a future update; CoNo then falls back to the play/pause media key and shows no song info for those apps.
- After a seek, you hear the new position after CoNo's delay (about 3–4 seconds) — the new audio has to go through the AI first.
- Occasional clicks can be heard in some sessions; a 96 kHz output device makes them more likely. Diagnostics are built in (Settings › Diagnostics).
- The vocal separation model weights come from the Ultimate Vocal Remover project and are downloaded separately; their license is not stated, so check it before redistributing. Lyrics come from the community-run LRCLIB service.

---

## 🗺 Roadmap

- [x] Lyrics, pitch bar and playback control for browsers and other music apps
- [x] Lyrics for music videos and live versions (title cleanup, wide auto sync)
- [x] "My key", guide vocal, pause/seek, interlude skip
- [x] More lyric sources: NetEase, AMLL TTML DB and optional Apple Music syllable lyrics
- [x] Signed and notarized release build
- [ ] Live "am I on pitch?" view on the pitch bar and microphone scoring — works with speakers, not just headphones
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

*Built by [AIB Inc.](https://www.aib.vote) · © 2026 AIB Inc.*
