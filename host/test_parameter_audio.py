"""Validate Phase 4 mixer-cell extraction and signed stereo return words."""
import os
import csv
import ctypes as c
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-audio"


class Frame(c.Structure):
    _fields_ = [("command", c.c_uint64 * 8), ("controls", c.c_uint64 * 256),
                ("control_count", c.c_uint), ("result_words", c.c_uint), ("parameter_bytes", c.c_uint)]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="PS_direct_mixer_diagnostic", success=False, hardware_verified=False)
    try:
        native = (Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe")
        arm = (Path(os.environ["VITIS_ROOT"]) / "gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
        source = ROOT / "software/ps/sc88_parameter_audio.c"
        flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(source.parent)]
        for compiler, extra, name in [(native, ["-shared"], "audio.dll"),
                                      (arm, ["-mcpu=cortex-a9", "-mfpu=vfpv3", "-mfloat-abi=hard", "-c"], "audio-arm.o")]:
            result = subprocess.run([str(compiler), *flags, *extra, str(source), "-o", str(OUT / name)], capture_output=True, text=True)
            (OUT / (name + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
            result.check_returncode()
        dll = c.CDLL(str(OUT / "audio.dll"))
        call = dll.sc88_parameter_diagnostic
        call.argtypes = [c.POINTER(Frame), c.POINTER(c.c_uint64), c.c_uint, c.c_uint, c.c_uint, c.POINTER(c.c_uint64)]
        call.restype = c.c_int
        frame, words, output = Frame(), (c.c_uint64 * 320)(), c.c_uint64()
        def initialize(voices, values, seen=0):
            frame.command[4] = voices - 1
            frame.result_words = voices * 4 + 64
            for cell, value in enumerate(values):
                words[voices * 4 + cell] = 1 << 63 | (seen >> cell & 1) << 62 | cell << 40 | (value & 0x1ffffff)
        def check(left, right, values):
            assert call(c.byref(frame), words, frame.result_words, left, right, c.byref(output)) == 0
            assert output.value == (values[left] & 0xffffffff) | (values[right] & 0xffffffff) << 32
        directed = 0
        values = [-8388608, -1, 0, 1, 8388607] * 13
        for voices in range(1, 65):
            initialize(voices, values[:64])
            for cell in range(64):
                check(cell, 63 - cell, values)
                directed += 1
        initialize(64, [0] * 64)
        negatives = 0
        def bad(count=320, left=0, right=1):
            nonlocal negatives
            output.value = 0x123456789abcdef0
            assert call(c.byref(frame), words, count, left, right, c.byref(output)) < 0
            assert output.value == 0x123456789abcdef0
            negatives += 1
        bad(319); bad(321); bad(left=64); bad(right=64)
        frame.result_words = 319; bad(); frame.result_words = 320
        for cell in [0, 1]:
            original = words[256 + cell]
            for bit in [63, 54, 48, 40, 25, 24]:
                words[256 + cell] = original ^ (1 << bit)
                bad()
            words[256 + cell] = original
        reference = ROOT / "build/verification/offline-player/phase-03/golden"
        with (reference / "manifest.csv").open(encoding="utf-8", newline="") as stream:
            cases = list(csv.DictReader(stream))
        frames = routes = 0
        for case in cases:
            with (reference / case["case"] / "mix.csv").open(encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
            assert len(rows) == int(case["frames"])
            for row in rows:
                values = [int(row[f"cell[{cell}]"]) for cell in range(64)]
                values = [(v & 0x7fffff) - (v & 0x800000) for v in values]
                initialize(int(case["voices"]), values, int(row["seen"]))
                for cell in range(64):
                    check(cell, 63 - cell, values)
                    routes += 1
                frames += 1
        report.update(success=True, arm_compile=True, directed_routes=directed, negatives=negatives,
                      reference_cases=len(cases), reference_frames=frames, reference_routes=routes,
                      limitation="Fixed-reference mixer-cell conversion only; no XP/LSP effects, MMIO/Cache, real MIDI board audio or timing evidence")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
