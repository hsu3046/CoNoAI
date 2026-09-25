# CoNo — Copyright (C) 2026 KnowAI — GPL-3.0-or-later
# 진단 녹음 WAV 에서 틱(샘플 단위 불연속) 위치를 찾는다. 표준 라이브러리만 사용.
#   python3 scripts/find_clicks.py ~/Downloads/CoNo-diagnostic-*/input-48000.wav
# 방법: 2차 차분 |x[n] − 2x[n−1] + x[n−2]| 가 주변 50 ms 의 중앙값 × THRESHOLD 이상이고 절대값도 충분히 큰 곳.
# 음악 자체의 타격음(드럼)도 걸릴 수 있으므로, 입력·출력 파일을 같이 보고 "출력에만 있는" 것을 찾는 데 쓴다.
import array
import sys
import wave

THRESHOLD = 12.0
MIN_ABS = 0.02
WINDOW_MS = 50


def load(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, "16-bit WAV 만 지원"
        rate, channels = w.getframerate(), w.getnchannels()
        data = array.array("h", w.readframes(w.getnframes()))
    if sys.byteorder == "big":
        data.byteswap()
    left = [data[i] / 32768.0 for i in range(0, len(data), channels)]
    return rate, left


def find_clicks(rate, x):
    d2 = [0.0, 0.0] + [abs(x[n] - 2 * x[n - 1] + x[n - 2]) for n in range(2, len(x))]
    block = max(1, int(rate * WINDOW_MS / 1000))
    clicks = []
    last = -rate
    for start in range(0, len(d2), block):
        segment = d2[start:start + block]
        if not segment:
            break
        median = sorted(segment)[len(segment) // 2] + 1e-6
        peak_index = max(range(len(segment)), key=segment.__getitem__)
        peak = segment[peak_index]
        n = start + peak_index
        if peak > MIN_ABS and peak / median > THRESHOLD and n - last > rate * 0.02:
            clicks.append((n / rate, peak, peak / median))
            last = n
    return clicks


for path in sys.argv[1:]:
    rate, x = load(path)
    clicks = find_clicks(rate, x)
    print(f"{path}: {len(x) / rate:.1f}초, 틱 후보 {len(clicks)}개")
    for t, peak, ratio in clicks[:40]:
        print(f"   {t:8.3f}s  크기 {peak:.3f}  주변 대비 {ratio:.0f}배")
