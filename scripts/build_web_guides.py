#!/usr/bin/env python3
# CoNo — Copyright (C) 2026 AIB Inc. (https://www.aib.vote) — GPL-3.0-or-later
"""Encode local browser captures into silent H.264 feature guides; no new dependencies."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def run(*args: str) -> None:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def encode(frames: list[tuple[Path, float]], target: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="cono-video-") as temporary:
        concat = Path(temporary) / "frames.txt"
        lines = []
        for path, duration in frames:
            if not path.is_file():
                raise FileNotFoundError(path)
            escaped = str(path.resolve()).replace("'", "'\\''")
            lines.extend([f"file '{escaped}'", f"duration {duration:.6f}"])
        lines.append(lines[-2])
        concat.write_text("\n".join(lines) + "\n")
        run("-f", "concat", "-safe", "0", "-i", str(concat), "-vf",
            "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x0b0d1a,setsar=1,fps=24",
            "-t", f"{sum(duration for _, duration in frames):.6f}",
            "-an", "-c:v", "libx264", "-crf", "23", "-preset", "medium", "-pix_fmt", "yuv420p", "-color_range", "tv",
            "-movflags", "+faststart", str(target))
        run("-ss", "0.5", "-i", str(target), "-frames:v", "1", "-q:v", "2", str(target.with_suffix(".jpg")))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, help="frames.json and browser JPEG captures")
    parser.add_argument("--output", type=Path, default=Path("web/public/videos"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    frames = [f for f in json.loads((args.captures / "frames.json").read_text()) if f["clip"] == "listen-master"]
    if len(frames) < 24:
        raise ValueError("A complete listen-master screencast is required")
    # A stopped screencast can leave an unacknowledged old frame; retain the final continuous take.
    cuts = [i for i in range(1, len(frames)) if frames[i]["time"] - frames[i - 1]["time"] > 1]
    frames = frames[cuts[-1]:] if cuts else frames
    durations = [b["time"] - a["time"] for a, b in zip(frames, frames[1:])] + [1 / 24]
    if not all(0 < duration <= 1 for duration in durations):
        raise ValueError("Capture timestamps are not monotonic")
    encode([(args.captures / frame["file"], duration) for frame, duration in zip(frames, durations)], args.output / "listen-guide.mp4")
    encode([(args.captures / f"scores-{name}.jpg", 4) for name in ["records", "share", "challenge"]], args.output / "scores-guide.mp4")
    print("Created two silent 1280×720 H.264 guides and posters.")


if __name__ == "__main__":
    main()
