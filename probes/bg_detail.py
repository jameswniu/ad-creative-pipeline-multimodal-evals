#!/usr/bin/env python3
"""bg_detail.py — is the BACKGROUND simple enough for avatar_iii to freeze it convincingly?

DERIVED FROM MY LABELS, 2026-07-26, not authored. I confirmed one set good and called the
next set "still a bit off"; the frames separate cleanly on exactly one measurable axis:

    take1-final-pro  GOOD   4.27      plain wall, sofa, one picture frame
    take3-final-pro  GOOD   3.61      plain bedroom wall, warm lamp
    R2 sunrise beach  off  7.05
    R1 flower stall   off 11.64     a wall of hundreds of roses and tulips
    R3 golden florist off 12.06

THRESHOLD 5.5 sits between my worst pass (4.27) and my best reject (7.05).

WHY IT MATTERS MECHANICALLY: avatar_iii animates ONLY her and freezes everything else into a
photograph. The more DETAIL sits behind her, the more obviously dead that photograph reads. A plain
warm wall has almost nothing to betray itself; a wall of individually-resolvable flowers has
thousands of edges all perfectly, unnaturally still for the whole clip.

Measures the SIDE BANDS only (left and right quarters), so she is excluded and the number is about
the scene, not about her.

Usage: bg_detail.py <image-or-video>   ->  exit 0 simple enough / 1 too busy
"""
import subprocess
import sys

import numpy as np

MAX_DETAIL = 5.5


def detail(path: str):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-vf",
                          "scale=256:256,format=gray", "-frames:v", "1", "-f", "rawvideo", "pipe:1"],
                         capture_output=True).stdout
    if len(raw) < 65536:
        return None
    f = np.frombuffer(raw[:65536], dtype=np.uint8).reshape(256, 256).astype(np.float32)
    side = np.concatenate([f[:, :64], f[:, 192:]], axis=1)
    return float((np.abs(np.diff(side, axis=1)).mean() + np.abs(np.diff(side, axis=0)).mean()) / 2)


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(64)
    d = detail(sys.argv[1])
    if d is None:
        print("bg_detail: unreadable")
        sys.exit(64)
    ok = d <= MAX_DETAIL
    print(f"BG {'SIMPLE' if ok else 'TOO BUSY'}: detail {d:.2f} (max {MAX_DETAIL}; "
          f"my passes 3.61-4.27, my rejects 7.05-12.06)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
