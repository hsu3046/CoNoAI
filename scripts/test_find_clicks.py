# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
import array
import json
from pathlib import Path
import sys
import tempfile
import unittest
import wave

from find_clicks import analyze, analyze_directory


class DiagnosticClickTests(unittest.TestCase):
    def write_wav(self, path, impulses, frames=48000):
        samples = array.array("h", [0]) * (frames * 2)
        for frame, channel in impulses:
            samples[frame * 2 + channel] = 24000
        if sys.byteorder == "big":
            samples.byteswap()
        with wave.open(str(path), "wb") as output:
            output.setnchannels(2)
            output.setsampwidth(2)
            output.setframerate(48000)
            output.writeframes(samples.tobytes())

    def test_right_channel_only_click_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "right.wav"
            self.write_wav(path, [(9600, 1)])
            result = analyze(path)
            self.assertEqual({item["channel"] for item in result["candidates"]}, {2})
            self.assertAlmostEqual(result["candidates"][0]["fileTime"], 0.2, delta=0.001)

    def test_report_aligns_different_snapshot_origins_and_detects_output_only(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            self.write_wav(directory / "in.wav", [(9600, 0)])
            self.write_wav(directory / "out.wav", [(9600, 1), (24000, 0)])
            report = {"schemaVersion": 1, "context": {"separationStreamOffsetSeconds": 1},
                      "input": {"fileName": "in.wav", "startFrame": 96000, "endFrame": 144000, "sampleRate": 48000, "channels": 2},
                      "output": {"fileName": "out.wav", "startFrame": 144000, "endFrame": 192000, "sampleRate": 48000, "channels": 2}}
            path = directory / "diagnostics.json"
            path.write_text(json.dumps(report))
            results = analyze_directory(directory)
            candidates = results[1]["candidates"]
            self.assertEqual([item["nearInputCandidate"] for item in candidates], [True, False])
            self.assertAlmostEqual(candidates[0]["captureTime"], 2.2, delta=0.001)
            report["output"]["endFrame"] += 1
            path.write_text(json.dumps(report))
            with self.assertRaises(ValueError):
                analyze_directory(directory)

    def test_short_and_empty_audio_do_not_invent_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            for frames in (0, 1, 2):
                path = Path(directory) / f"{frames}.wav"
                self.write_wav(path, [], frames=frames)
                self.assertEqual(analyze(path)["candidates"], [])

    def test_non_object_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "diagnostics.json").write_text("[]")
            with self.assertRaises(ValueError):
                analyze_directory(directory)


if __name__ == "__main__":
    unittest.main()
