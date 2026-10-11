"""Validate launch acknowledgement, first Ramp steps and coefficient refresh against pinned XP steps."""
import json
import re
import shutil
import subprocess

from test_filter_tva import ROOT, run

OUT = ROOT / "build/verification/phase-02-rtl/source-control"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="source_control_component", success=False, hardware_verified=False)
    try:
        shutil.copyfile(ROOT / "hardware/rtl/xp3_pitch.mem", OUT / "xp3_pitch.mem")
        with (OUT / "reference-build.log").open("w", encoding="utf-8") as log:
            subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_voice_reference.ps1")], stdout=log, stderr=subprocess.STDOUT, check=True)
        reference = subprocess.run([str(ROOT / "build/voice-reference/Release/sc88_source_control_vectors.exe"), str(OUT / "vectors.txt")], capture_output=True, text=True, check=True)
        assert "SOURCE_CONTROL_VECTORS_COMPLETE count=40960" in reference.stdout
        (OUT / "reference.log").write_text(reference.stdout, encoding="utf-8")
        files = ["hardware/rtl/xp3_ramp_math.sv", "hardware/rtl/xp3_control_math.sv", "hardware/rtl/xp3_source_control.sv", "hardware/sim/tb_source_control.sv"]
        run("xvlog.bat", ["--sv", *[str(ROOT / f) for f in files]], OUT)
        run("xelab.bat", ["tb_source_control", "-s", "source_control", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["source_control", "-runall"], OUT)
        match = re.search(r"SOURCE_CONTROL_PASS vectors=40960 worst_cycles=(\d+) reset_positions=(\d+)", log)
        assert match and "Fatal:" not in log
        report.update(success=True, vectors=40960, worst_cycles=int(match[1]), reset_positions=int(match[2]),
                      limit="Source launch and coefficient refresh only; full Voice still requires integration")
        print(f"SOURCE_CONTROL_COMPONENT_PASS vectors=40960 worst_cycles={match[1]}")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
