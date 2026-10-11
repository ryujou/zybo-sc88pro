"""Validate pending/hold, slot timing and terminal IRQs against actual pinned XP steps."""
import json
import re
import shutil
import subprocess

from test_filter_tva import ROOT, run

OUT = ROOT / "build/verification/phase-02-rtl/ramp-service"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="ramp_service_component", success=False, hardware_verified=False)
    try:
        shutil.copyfile(ROOT / "hardware/rtl/xp3_pitch.mem", OUT / "xp3_pitch.mem")
        with (OUT / "reference-build.log").open("w", encoding="utf-8") as log:
            subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_voice_reference.ps1")], stdout=log, stderr=subprocess.STDOUT, check=True)
        reference = subprocess.run([str(ROOT / "build/voice-reference/Release/sc88_ramp_service_vectors.exe"), str(OUT / "vectors.txt")], capture_output=True, text=True, check=True)
        assert "RAMP_SERVICE_VECTORS_COMPLETE count=40960" in reference.stdout
        (OUT / "reference.log").write_text(reference.stdout, encoding="utf-8")
        files = ["hardware/rtl/xp3_ramp_math.sv", "hardware/rtl/xp3_control_math.sv", "hardware/rtl/xp3_ramp_service.sv", "hardware/sim/tb_ramp_service.sv"]
        run("xvlog.bat", ["--sv", *[str(ROOT / f) for f in files]], OUT)
        run("xelab.bat", ["tb_ramp_service", "-s", "ramp_service", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["ramp_service", "-runall"], OUT)
        match = re.search(r"RAMP_SERVICE_PASS vectors=40960 worst_cycles=(\d+) reset_positions=(\d+)", log)
        assert match and "Fatal:" not in log
        report.update(success=True, vectors=40960, worst_cycles=int(match[1]), reset_positions=int(match[2]),
                      limit="Selected running-slot service; source/launch/Loop arbitration and full Voice still require integration")
        print(f"RAMP_SERVICE_COMPONENT_PASS vectors=40960 worst_cycles={match[1]}")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
