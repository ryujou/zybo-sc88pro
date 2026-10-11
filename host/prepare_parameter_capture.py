"""Build software-only assertions for seven USB parameter-player capture windows."""
import csv
import json
from pathlib import Path
import struct
import subprocess

from prepare_voice_probe import main as voice_overlay
from prepare_board_probe import main as board_overlay

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/hardware/golden"
FIRST, FRAMES = 352000, 2048


def encode_assertions(source, output, song):
    records = [[] for _ in range(FRAMES)]
    native = []
    with (source / "sends.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            frame = int(row["frame"])
            if not FIRST <= frame < FIRST + FRAMES:
                continue
            voice, send = int(row["voice"]), int(row["send"])
            assert len(records[frame - FIRST]) == voice * 4 + send
            records[frame - FIRST].append((int(row["slot"]) << 54) | (voice << 48) | (send << 46) |
                                         (int(row["destination"]) << 40) | (int(row["contribution"]) & 0x1ffffff))
    with (source / "mix.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            frame = int(row["frame"])
            if not FIRST <= frame < FIRST + FRAMES:
                continue
            assert frame == FIRST + len(native)
            seen = int(row["seen"])
            records[frame - FIRST].extend((1 << 63) | (((seen >> cell) & 1) << 62) | (cell << 40) |
                                         (int(row[f"cell[{cell}]"]) & 0x1ffffff) for cell in range(64))
            native.append((int(row["cell[8]"]), int(row["cell[9]"])))
    assert len(native) == FRAMES and all(68 <= len(row) <= 320 for row in records)
    output.mkdir(parents=True, exist_ok=True)
    (output / "expected-results.bin").write_bytes(b"".join(
        struct.pack("<322Q", FIRST + index, len(row), *row, *([0] * (320 - len(row))))
        for index, row in enumerate(records)))
    (output / "expected-dry89.pcm").write_bytes(b"".join(struct.pack("<ii", *row) for row in native))
    result = dict(scope="software_diagnostic_assertions_only", song=song, source=str(source.relative_to(ROOT)),
                  first_frame=FIRST, frames=FRAMES, records=sum(map(len, records)), result_words=sorted(set(map(len, records))),
                  left_peak=max(abs(left) for left, right in native), right_peak=max(abs(right) for left, right in native),
                  hardware_verified=False)
    assert result["left_peak"] and result["right_peak"], "Diagnostic window must exercise both channels"
    (output / "expected.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="seven_parameter_capture_software_assertions", success=False, hardware_verified=False, songs=[])

    def execute(command, log):
        with log.open("w", encoding="utf-8") as stream:
            subprocess.run(list(map(str, command)), cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)

    try:
        lock = json.loads((ROOT / "reference/gearmulator-lock.json").read_text(encoding="utf-8"))
        upstream = ROOT / "external/gearmulator"
        assert subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip() == lock["commit"]
        assert not subprocess.check_output(["git", "-C", str(upstream), "status", "--porcelain"], text=True).strip()
        voice_overlay()
        board_overlay()
        execute(["cmake", "-S", "host/voice_reference", "-B", "build/board-reference", "-G", "Visual Studio 17 2022", "-A", "x64", "-DSC88_BOARD_PROBE=ON"], OUT / "configure.log")
        execute(["cmake", "--build", "build/board-reference", "--config", "Release", "--target", "sc88_board_trace_probe", "--parallel", "8"], OUT / "build.log")
        for number in range(1, 8):
            song = f"th06_{number:02d}"
            baseline = ROOT / "build/verification/th06-midi" / song
            result = json.loads((baseline / "result.json").read_text(encoding="utf-8"))
            assert result["status"] == "通过" and result["boot_frames"] <= FIRST
            assert FIRST + FRAMES <= result["boot_frames"] + result["case_frames"]
            output = OUT / song
            output.mkdir(parents=True, exist_ok=True)
            execute([ROOT / "build/board-reference/Release/sc88_board_trace_probe.exe", ROOT / "private/roms",
                     baseline / "export/register.trace", output, lock["commit"], FIRST, FRAMES], output / "capture.log")
            with (baseline / "reference/native.pcm").open("rb") as stream:
                stream.seek((FIRST - result["boot_frames"]) * 8)
                original = stream.read(FRAMES * 8)
            assert len(original) == FRAMES * 8 and (output / "reference.pcm").read_bytes() == original, song
            summary = encode_assertions(output, output, song)
            summary["reference_pcm_exact"] = True
            report["songs"].append(summary)
            print(f"{song}: {FRAMES} fixed-reference frames, {summary['records']} records", flush=True)
        report["success"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
