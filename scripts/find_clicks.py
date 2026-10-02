#!/usr/bin/env python3
# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"""진단 WAV 양쪽 채널의 불연속 후보. 표준 라이브러리만 사용한다.

python3 scripts/find_clicks.py ~/Downloads/CoNo-diagnostic-...
python3 scripts/find_clicks.py input.wav output.wav

타악기도 후보가 될 수 있다. 출력에만 있는 후보 역시 클릭 확정 판정이 아니다.
"""
import argparse
import array
import json
import math
from pathlib import Path
import sys
import wave

THRESHOLD = 12.0
MIN_ABS = 0.02
WINDOW_MS = 50


def load(path):
    with wave.open(str(path), "rb") as wav:
        if wav.getsampwidth() != 2 or wav.getcomptype() != "NONE":
            raise ValueError("16-bit PCM WAV만 지원합니다")
        rate, channels, frames = wav.getframerate(), wav.getnchannels(), wav.getnframes()
        data = array.array("h", wav.readframes(frames))
    if rate <= 0 or channels < 1 or len(data) != frames * channels:
        raise ValueError("WAV 헤더와 오디오 데이터 길이가 일치하지 않습니다")
    if sys.byteorder == "big":
        data.byteswap()
    return rate, [[data[i] / 32768.0 for i in range(channel, len(data), channels)] for channel in range(channels)]


def find_clicks(rate, samples):
    d2 = [0.0] * min(2, len(samples)) + [abs(samples[n] - 2 * samples[n - 1] + samples[n - 2]) for n in range(2, len(samples))]
    block = max(1, int(rate * WINDOW_MS / 1000))
    clicks = []
    last = -rate
    for start in range(0, len(d2), block):
        segment = d2[start:start + block]
        median = sorted(segment)[len(segment) // 2] + 1e-6
        peak_index = max(range(len(segment)), key=segment.__getitem__)
        peak = segment[peak_index]
        n = start + peak_index
        if peak > MIN_ABS and peak / median > THRESHOLD and n - last > rate * 0.02:
            clicks.append((n / rate, peak, peak / median))
            last = n
    return clicks


def analyze(path, metadata=None, stream_offset=0):
    rate, channels = load(path)
    start = 0.0
    if metadata is not None:
        if not isinstance(metadata, dict):
            raise ValueError("진단 WAV 메타데이터가 올바르지 않습니다")
        start_frame, end_frame = metadata.get("startFrame"), metadata.get("endFrame")
        if (type(start_frame) is not int or type(end_frame) is not int or start_frame < 0
                or end_frame - start_frame != len(channels[0])
                or metadata.get("sampleRate") != rate or metadata.get("channels") != len(channels)):
            raise ValueError("diagnostics.json과 WAV의 프레임·레이트·채널이 일치하지 않습니다")
        start = start_frame / rate - stream_offset
    candidates = []
    for channel, samples in enumerate(channels):
        for local_time, peak, ratio in find_clicks(rate, samples):
            candidates.append({"channel": channel + 1, "fileTime": local_time,
                               "captureTime": start + local_time, "peak": peak, "ratio": ratio})
    candidates.sort(key=lambda item: (item["captureTime"], item["channel"]))
    return {"path": str(path), "seconds": len(channels[0]) / rate, "candidates": candidates}


def analyze_directory(directory):
    directory = Path(directory)
    report = json.loads((directory / "diagnostics.json").read_text())
    if not isinstance(report, dict) or report.get("schemaVersion") != 1:
        raise ValueError("지원하지 않는 diagnostics.json 버전입니다")
    offset = report["context"]["separationStreamOffsetSeconds"]
    if isinstance(offset, bool) or not isinstance(offset, (int, float)) or not math.isfinite(offset) or not 0 <= offset <= 60:
        raise ValueError("분리 스트림 시각 오프셋이 올바르지 않습니다")
    results = []
    for stage in ("input", "output"):
        metadata = report[stage]
        if not isinstance(metadata, dict):
            raise ValueError("진단 WAV 메타데이터가 올바르지 않습니다")
        name = metadata["fileName"]
        if not isinstance(name, str) or Path(name).name != name or name in ("", ".", ".."):
            raise ValueError("진단 파일 이름이 올바르지 않습니다")
        results.append(analyze(directory / name, metadata, offset if stage == "output" else 0))
    input_candidates = results[0]["candidates"]
    for candidate in results[1]["candidates"]:
        candidate["nearInputCandidate"] = any(
            abs(candidate["captureTime"] - original["captureTime"]) <= 0.02
            for original in input_candidates
        )
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", type=Path, help="진단 폴더 또는 16-bit PCM WAV")
    args = parser.parse_args()
    try:
        for path in args.paths:
            paired = path.is_dir()
            results = analyze_directory(path) if paired else [analyze(path)]
            for result in results:
                print(f"{result['path']}: {result['seconds']:.1f}초, 불연속 후보 {len(result['candidates'])}개")
                for item in result["candidates"][:40]:
                    time = f"파일 {item['fileTime']:.3f}s"
                    if paired:
                        time += f", 캡처 스트림 {item['captureTime']:.3f}s"
                    match = ""
                    if "nearInputCandidate" in item:
                        match = " · 입력 근처에도 후보" if item["nearInputCandidate"] else " · 출력에서만 후보"
                    print(f"  채널 {item['channel']} {time} · 크기 {item['peak']:.3f}, 주변 대비 {item['ratio']:.0f}배{match}")
            if not paired:
                print("  개별 WAV의 파일 시각은 서로 정렬되지 않을 수 있습니다. 진단 폴더를 지정하면 스트림 시각으로 비교합니다.")
        print("후보는 클릭 확정이 아닙니다. WAV에는 재생 렌더·키 조절·실제 장치 이후 소리가 포함되지 않습니다.")
    except (OSError, ValueError, KeyError, TypeError, wave.Error) as error:
        parser.exit(1, f"진단 파일을 읽지 못했습니다: {error}\n")


if __name__ == "__main__":
    main()
