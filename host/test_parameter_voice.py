"""Parameter-driven RTL versus fixed original Voice state, ROM and stage observations."""
import argparse
from collections import defaultdict
import json
import re
import shutil

from test_filter_tva import ROOT, rows, run
import test_voice
import test_voice_trace

BASE = ROOT / "build/verification/offline-player/phase-02"
RTL = ["xp3_sample_pkg", "xp3_voice_state", "xp3_interpolate", "xp3_wave_source", "xp3_filter_tva", "xp3_pair_filter", "xp3_parameter_voice"]


def hooks(directory):
    result = defaultdict(list)
    for row in rows(directory / "parameters.csv"):
        result[int(row["frame"])].append([row["voice"], row["stage"], row["mask"], row["terminal"], *[row[f"value{i}"] for i in range(22)]])
    return result


def simulate(kind):
    out = BASE / ("voice-" + kind)
    out.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_voice_" + kind, success=False, hardware_verified=False)
    try:
        if kind == "piano":
            test_voice_trace.OUT = out
            test_voice_trace.REFERENCE = BASE / "parameter-reference"
            count = test_voice_trace.vectors(parameter_hooks=hooks)
            cases = 1
            shutil.copyfile(BASE / "reference/trace-piano/decoded-wave.bin", out / "decoded-wave.bin")
        else:
            test_voice.OUT = out
            source = BASE / "parameter-reference" / ("golden" if kind == "synthetic" else "pressure")
            names = [row["case"] for row in rows(source / "manifest.csv")]
            cases = test_voice.vectors(source, names, parameter_hooks=hooks)
            count = cases * 256
        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", out / "xp3_interpolation.mem")
        run("xvlog.bat", ["--sv", *[str(ROOT / "hardware/rtl" / (name + ".sv")) for name in RTL], str(ROOT / "hardware/sim/tb_parameter_voice.sv")], out)
        run("xelab.bat", ["tb_parameter_voice", "-s", "parameter_voice", "--debug", "typical"], out)
        arguments = ["parameter_voice", "-runall"]
        if kind != "synthetic":
            arguments += ["-testplusarg", "trace" if kind == "piano" else "pressure"]
        def execute(name, extras):
            log = run("xsim.bat", arguments + extras, out)
            (out / (name + ".log")).write_text(log, encoding="utf-8")
            match = re.search(r"VOICE_SYNTHETIC_PASS cases=(\d+) frames=(\d+) single_cycles=(\d+) pair_cycles=(\d+)", log)
            assert match and int(match[1]) == cases and int(match[2]) == count and "Fatal:" not in log
            stage = re.search(r"VOICE_STAGES_PASS count=(\d+)", log)
            parameters = re.search(r"PARAMETER_HOOKS_PASS count=(\d+)", log)
            assert stage and parameters and int(parameters[1]) > 0
            return log, dict(single_cycles=int(match[3]), pair_cycles=int(match[4]), stages=int(stage[1]), parameter_hooks=int(parameters[1]))
        log, nominal = execute("nominal", [])
        report.update(numeric_match=True, cases=cases, frames=count, **nominal)
        assert nominal["single_cycles"] <= 44 and nominal["pair_cycles"] <= 88, "Parameter Voice exceeds 44/88 nominal cycles"
        if kind == "synthetic":
            assert "VOICE_RESET_PASS checks=512" in log and "VOICE_CONFIG_PASS" in log
            _, stalled = execute("stalls", ["-testplusarg", "stalls", "-testplusarg", "parameter_late"])
            report.update(reset_positions=512, stalls_passed=True, stalled=stalled)
            faults = []
            for fault in ["damage_rom", "damage_state", "phase_error", "coefficient", "duplicate_rom", "missing_rom", "parameter_coefficient", "parameter_frame", "parameter_voice", "parameter_stage", "parameter_mask", "parameter_width", "parameter_hold", "parameter_reason", "parameter_missing", "parameter_duplicate"]:
                if fault == "coefficient":
                    table = (out / "xp3_interpolation.mem").read_text(encoding="utf-8").splitlines()
                    table[0] = format(int(table[0], 16)^1, "x")
                    (out / "xp3_interpolation.mem").write_text("\n".join(table)+"\n", encoding="utf-8")
                try:
                    negative = run("xsim.bat", arguments + ["-testplusarg", fault], out)
                except RuntimeError:
                    negative = (out / "xsim.bat.log").read_text(encoding="utf-8")
                finally:
                    if fault == "coefficient":
                        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", out / "xp3_interpolation.mem")
                (out / ("negative-" + fault + ".log")).write_text(negative, encoding="utf-8")
                assert "VOICE_SYNTHETIC_PASS" not in negative and any(message in negative for message in ["VOICE_STATE_DIFFERENCE", "VOICE_RESULT_DIFFERENCE", "VOICE_STAGE_INPUT", "VOICE_FILTER_STAGE", "VOICE_ROM_DIFFERENCE", "Unexpected ROM transaction", "PARAMETER_PROTOCOL_FAULT", "PARAMETER_MISSING_TIMEOUT"]), fault
                faults.append(fault)
            report["negative_faults_detected"] = faults
        report["success"] = True
        print(json.dumps(report), flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (out / "summary.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", choices=["synthetic", "pressure", "piano"], default="synthetic")
    simulate(parser.parse_args().kind)
