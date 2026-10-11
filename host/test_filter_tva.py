"""Component-only XSim checks against pinned XP stage observations, not a Voice gate."""
import os
import csv
import itertools
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/phase-02-rtl/filter-tva"
REFERENCE = OUT.parent / "reference"
VIVADO = (Path(os.environ["VIVADO_ROOT"]) / "bin")


def rows(path):
    with path.open(encoding="utf-8", newline="") as stream:
        yield from csv.DictReader(stream)


def signed24(value):
    value = int(value)
    return value - (1 << 24) if value & (1 << 23) else value


def vectors(output, directory, trace=False, stage_kind="filter_tva"):
    initial = "voice-initial.csv" if trace else "initial.csv"
    expected = "voice-expected.csv" if trace else "expected.csv"
    stages = "voice-stages.csv" if trace else "stages.csv"
    events = "voice-controls.csv" if trace else "events.csv"
    state = next(rows(directory / initial))
    state = {name: int(value) for name, value in state.items()}
    first_voice = 62 if trace else 0
    stage_groups = iter(itertools.groupby(rows(directory / stages), key=lambda r: int(r["frame"])))
    event_groups = iter(itertools.groupby(rows(directory / events), key=lambda r: int(r["frame"])))
    stage_frame, stage_rows = next(stage_groups, (None, []))
    event_frame, event_rows = next(event_groups, (None, []))
    count = 0
    for post in rows(directory / expected):
        frame = int(post["frame"])
        if event_frame == frame:
            for event in event_rows:
                name, value = event["event"], int(event["value"])
                if name == "powerReset":
                    state = {key: 0 for key in state}
                elif name in state:
                    state[name] = value
                elif name == "releaseMask":
                    for voice in range(first_voice, first_voice + 2):
                        prefix = f"voice[{voice}]."
                        shadow = state[prefix + "resetState_3900.shadow"]
                        released = (value >> voice) & 1
                        if shadow and not released:
                            state[prefix + "resetState_3900.released"] = 0
                        state[prefix + "resetState_3900.shadow"] = released
                elif name == "commitRelease":
                    for voice in range(first_voice, first_voice + 2):
                        prefix = f"voice[{voice}]."
                        if state[prefix + "resetState_3900.shadow"]:
                            state[prefix + "resetState_3900.released"] = 1
            event_frame, event_rows = next(event_groups, (None, []))
        for voice in range(first_voice, first_voice + 2):
            prefix = f"voice[{voice}]."
            if not state[prefix + "resetState_3900.released"]:
                state[prefix + "filterBp_2800"] = state[prefix + "filterLp_2900"] = 0
        if stage_frame == frame:
            for stage in stage_rows:
                wanted = ("filter", "tva") if stage_kind == "filter_tva" else ("interpolation",)
                if stage["stage"] not in wanted:
                    continue
                prefix = f"voice[{first_voice + int(stage['voice'])}]."
                a, b, c, d, e, f, g, h = [int(stage[k]) for k in "abcdefgh"]
                if stage["stage"] == "interpolation":
                    consumer = a >> 14
                    cells = [state[prefix + f"waveCircularBuffer_0800[{(consumer + tap) & 7}]"] for tap in range(3)]
                    values = [state[prefix + "runtimeCache.waveSampleFormat"],
                              (state[prefix + "playbackStateConfig_1000"] >> 3) & 3,
                              (a >> 7) & 127, state[prefix + "dpcmAccumulator_0c00"], *cells, b]
                elif stage["stage"] == "filter":
                    old_bp = signed24(state[prefix + "filterBp_2800"])
                    old_lp = signed24(state[prefix + "filterLp_2900"])
                    values = [0, b & 3, a, old_bp, old_lp, g, h, 0, f, e, c, d]
                    state[prefix + "filterBp_2800"] = e & 0xffffff
                    state[prefix + "filterLp_2900"] = c & 0xffffff
                else:
                    values = [1, 0, a, 0, 0, 0, 0, b >> 4, c, 0, 0, 0]
                output.write(" ".join(map(str, values)) + "\n")
                count += 1
            stage_frame, stage_rows = next(stage_groups, (None, []))
        # Stage-unit stimulus uses observed pre-state; full Voice tests must advance independently.
        state = {name: int(value) for name, value in post.items()}
    assert stage_frame is None and event_frame is None, f"Unconsumed observations in {directory}"
    return count


def run(name, arguments, directory=OUT):
    result = subprocess.run([str(VIVADO / name), *arguments], cwd=directory, capture_output=True, text=True, encoding="utf-8", errors="replace")
    (directory / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{name} failed ({result.returncode}); see {directory / (name + '.log')}")
    return result.stdout + result.stderr


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="filter_tva_component", success=False, hardware_verified=False)
    try:
        contract = json.loads((ROOT / "reference/phase2-contract.json").read_text(encoding="utf-8"))
        counts = {}
        with (OUT / "vectors.txt").open("w", encoding="utf-8", newline="\n") as stream:
            for name in contract["cases"]:
                counts[name] = vectors(stream, REFERENCE / "golden" / name)
            counts["trace-piano"] = vectors(stream, REFERENCE / "trace-piano", trace=True)
        assert sum(counts.values()) > 0
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/rtl/xp3_filter_tva.sv"), str(ROOT / "hardware/sim/tb_filter_tva.sv")])
        run("xelab.bat", ["tb_filter_tva", "-s", "filter_tva", "--debug", "typical"])
        log = run("xsim.bat", ["filter_tva", "-runall"])
        assert f"FILTER_TVA_PASS vectors={sum(counts.values())} " in log and "Fatal:" not in log, "Missing success marker or RTL assertion failed"
        report.update(success=True, vectors=sum(counts.values()), cases=counts, filter_cycles=6, tva_cycles=2, reset_positions=7,
                      limit="Component inputs include observed pre-state; this does not prove independent Voice state progression or Phase 2 B")
        print(f"FILTER_TVA_COMPONENT_PASS vectors={sum(counts.values())}")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
