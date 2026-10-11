"""Check the complete paired audio path against fixed XP pair-structure cases."""
import itertools
import json
import re

from test_filter_tva import ROOT, REFERENCE, rows, run, signed24

OUT = ROOT / "build/verification/phase-02-rtl/pair-filter"


def pair_vectors(stream, directory):
    state = {key: int(value) for key, value in next(rows(directory / "initial.csv")).items()}
    groups = iter(itertools.groupby(rows(directory / "stages.csv"), key=lambda r: int(r["frame"])))
    stage_frame, stages = next(groups, (None, []))
    count = 0
    for post in rows(directory / "expected.csv"):
        frame = int(post["frame"])
        if stage_frame == frame:
            observations = list(stages)
            inputs = {int(s["voice"]): int(s["b"]) for s in observations if s["stage"] == "interpolation"}
            if inputs:
                values = [state["voice[0].filterConfig_2000"], inputs.get(0, 0), inputs.get(1, 0)]
                for voice in range(2):
                    p = f"voice[{voice}]."
                    gain = state[p + "tvaGain_2700"]
                    if state[p + "resetState_3900.released"] and state[p + "runtimeCache.runtimePhase"] in (3, 4):
                        gain = (7 * gain + (state[p + "combinedAmp_2300"] >> 4) + 3) >> 3
                    assert gain == int(post[p + "tvaGain_2700"])
                    values.extend([signed24(state[p + "filterBp_2800"]), signed24(state[p + "filterLp_2900"]),
                                   state[p + "tvfFCoefficient_2200"], state[p + "tvfQCurrent_2100"], gain])
                values.append(signed24(post["voice[0].filterOutput_2a00"]))
                assert int(post["voice[1].filterOutput_2a00"]) == 0
                for voice in range(2):
                    values.extend([signed24(post[f"voice[{voice}].filterBp_2800"]), signed24(post[f"voice[{voice}].filterLp_2900"])])
                stream.write(" ".join(map(str, values)) + "\n")
                count += 1
            stage_frame, stages = next(groups, (None, []))
        state = {key: int(value) for key, value in post.items()}
    assert stage_frame is None and count > 0
    return count


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="pair_filter_component", success=False, hardware_verified=False)
    try:
        counts = {}
        with (OUT / "vectors.txt").open("w", encoding="utf-8", newline="\n") as stream:
            for structure in range(2, 11):
                name = f"pair_structure_{structure}"
                counts[name] = pair_vectors(stream, REFERENCE / "golden" / name)
        run("xvlog.bat", ["--sv", *[str(ROOT / path) for path in ["hardware/rtl/xp3_filter_tva.sv", "hardware/rtl/xp3_pair_filter.sv", "hardware/sim/tb_pair_filter.sv"]]], OUT)
        run("xelab.bat", ["tb_pair_filter", "-s", "pair_filter", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["pair_filter", "-runall"], OUT)
        match = re.search(r"PAIR_FILTER_PASS vectors=(\d+) worst_cycles=(\d+) reset_positions=(\d+)", log)
        assert match and int(match[1]) == sum(counts.values()) and "Fatal:" not in log
        (OUT / "positive.log").write_text(log, encoding="utf-8")
        original = (OUT / "vectors.txt").read_bytes()
        lines = original.decode("utf-8").splitlines(keepends=True)
        first = lines[0].split()
        first[3] = str(signed24((int(first[3]) & 0xffffff) ^ 1))
        lines[0] = " ".join(first) + "\n"
        try:
            (OUT / "vectors.txt").write_text("".join(lines), encoding="utf-8", newline="\n")
            try:
                negative = run("xsim.bat", ["pair_filter", "-runall"], OUT)
            except RuntimeError:
                negative = (OUT / "xsim.bat.log").read_text(encoding="utf-8")
            (OUT / "negative-state.log").write_text(negative, encoding="utf-8")
            assert "PAIR_DIFFERENCE vector=" in negative and "PAIR_FILTER_PASS" not in negative, "State-bit corruption was not detected"
        finally:
            (OUT / "vectors.txt").write_bytes(original)
        report.update(success=True, vectors=sum(counts.values()), cases=counts, worst_cycles=int(match[2]), reset_positions=int(match[3]),
                      state_bit_negative_detected=True,
                      limit="Paired audio path only; source/Ramp inputs are observed component stimuli, not independent full Voice progression")
        print(f"PAIR_FILTER_COMPONENT_PASS vectors={sum(counts.values())} worst_cycles={match[2]}")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
