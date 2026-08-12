#!/usr/bin/env python3
"""Build an FFmpeg audio filter that removes detected long silences.

The detector log comes from FFmpeg's silencedetect filter. For an internal
silence, the configured retained silence is split evenly across both sides of
the cut. For leading or trailing silence, all retained silence is kept adjacent
to speech/audio rather than at the empty edge of the file.
"""

from __future__ import annotations

import argparse
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

START_RE = re.compile(r"silence_start:\s*([-+0-9.eE]+)")
END_RE = re.compile(
    r"silence_end:\s*([-+0-9.eE]+)(?:\s*\|\s*silence_duration:\s*([-+0-9.eE]+))?"
)


@dataclass(frozen=True)
class Interval:
    start: float
    end: float

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log-file", required=True, type=Path)
    parser.add_argument("--duration", required=True, type=float)
    parser.add_argument("--keep-silence", required=True, type=float)
    parser.add_argument("--filter-script", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args()


def parse_silences(log_text: str, total_duration: float) -> list[Interval]:
    pending_start: float | None = None
    intervals: list[Interval] = []

    for line in log_text.splitlines():
        start_match = START_RE.search(line)
        if start_match:
            pending_start = float(start_match.group(1))
            continue

        end_match = END_RE.search(line)
        if end_match:
            end = float(end_match.group(1))
            if pending_start is not None:
                start = pending_start
            elif end_match.group(2) is not None:
                start = end - float(end_match.group(2))
            else:
                continue

            pending_start = None
            start = min(max(start, 0.0), total_duration)
            end = min(max(end, start), total_duration)
            if end > start:
                intervals.append(Interval(start, end))

    if pending_start is not None and pending_start < total_duration:
        intervals.append(Interval(max(0.0, pending_start), total_duration))

    intervals.sort(key=lambda item: (item.start, item.end))
    return intervals


def cuts_from_silences(
    silences: list[Interval], total_duration: float, keep_silence: float
) -> list[Interval]:
    epsilon = 1e-3
    cuts: list[Interval] = []

    for silence in silences:
        retained = min(max(keep_silence, 0.0), silence.duration)

        if silence.start <= epsilon:
            # Keep the safety silence immediately before the first audible sound.
            cut = Interval(0.0, silence.end - retained)
        elif silence.end >= total_duration - epsilon:
            # Keep the safety silence immediately after the final audible sound.
            cut = Interval(silence.start + retained, total_duration)
        else:
            left_keep = retained / 2.0
            right_keep = retained - left_keep
            cut = Interval(silence.start + left_keep, silence.end - right_keep)

        if cut.duration > epsilon:
            cuts.append(cut)

    # Merge any overlapping cut intervals produced by adjacent detector events.
    merged: list[Interval] = []
    for cut in sorted(cuts, key=lambda item: (item.start, item.end)):
        if not merged or cut.start > merged[-1].end + epsilon:
            merged.append(cut)
        else:
            merged[-1] = Interval(merged[-1].start, max(merged[-1].end, cut.end))
    return merged


def complement(cuts: list[Interval], total_duration: float) -> list[Interval]:
    epsilon = 1e-6
    kept: list[Interval] = []
    cursor = 0.0

    for cut in cuts:
        if cut.start > cursor + epsilon:
            kept.append(Interval(cursor, cut.start))
        cursor = max(cursor, cut.end)

    if cursor < total_duration - epsilon:
        kept.append(Interval(cursor, total_duration))

    return [segment for segment in kept if segment.duration > epsilon]


def fmt(value: float) -> str:
    if not math.isfinite(value):
        raise ValueError("non-finite timestamp")
    return f"{value:.6f}".rstrip("0").rstrip(".") or "0"


def build_filter(kept: list[Interval]) -> str:
    if not kept:
        # A fully silent file can legitimately collapse to the retained safety
        # interval. This fallback emits a tiny valid silent stream.
        return "anullsrc=r=48000:cl=mono:d=0.01[outa]\n"

    if len(kept) == 1:
        segment = kept[0]
        return (
            f"[0:a:0]atrim=start={fmt(segment.start)}:end={fmt(segment.end)},"
            "asetpts=PTS-STARTPTS[outa]\n"
        )

    lines: list[str] = []
    labels: list[str] = []
    for index, segment in enumerate(kept):
        label = f"a{index}"
        labels.append(f"[{label}]")
        lines.append(
            f"[0:a:0]atrim=start={fmt(segment.start)}:end={fmt(segment.end)},"
            f"asetpts=PTS-STARTPTS[{label}]"
        )

    lines.append(f"{''.join(labels)}concat=n={len(labels)}:v=0:a=1[outa]")
    return ";\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    if args.duration <= 0:
        raise SystemExit("duration must be positive")
    if args.keep_silence < 0:
        raise SystemExit("keep-silence must be non-negative")

    log_text = args.log_file.read_text(encoding="utf-8", errors="replace")
    silences = parse_silences(log_text, args.duration)
    cuts = cuts_from_silences(silences, args.duration, args.keep_silence)
    kept = complement(cuts, args.duration)

    args.filter_script.parent.mkdir(parents=True, exist_ok=True)
    args.filter_script.write_text(build_filter(kept), encoding="utf-8")

    removed_seconds = sum(interval.duration for interval in cuts)
    payload = {
        "source_duration_seconds": args.duration,
        "detected_silence_intervals": [interval.__dict__ for interval in silences],
        "removed_intervals": [interval.__dict__ for interval in cuts],
        "kept_intervals": [interval.__dict__ for interval in kept],
        "estimated_removed_seconds": removed_seconds,
        "estimated_output_seconds": max(0.0, args.duration - removed_seconds),
        "retained_silence_seconds": args.keep_silence,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
