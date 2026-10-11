"""Check shared Ramp RTL against pinned C++ helpers and actual XP Amp-trunk steps."""
import json
import subprocess

from test_filter_tva import ROOT, run

OUT = ROOT / "build/verification/phase-02-rtl/ramp-math"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="ramp_math_component", success=False, hardware_verified=False)
    try:
        with (OUT / "reference-build.log").open("w", encoding="utf-8") as log:
            subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_voice_reference.ps1")], stdout=log, stderr=subprocess.STDOUT, check=True)
        reference = subprocess.run([str(ROOT / "build/voice-reference/Release/sc88_ramp_vectors.exe"), str(OUT / "vectors.txt")], capture_output=True, text=True, check=True)
        assert "RAMP_VECTORS_COMPLETE count=65536" in reference.stdout
        (OUT / "reference.log").write_text(reference.stdout, encoding="utf-8")
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/rtl/xp3_ramp_math.sv"), str(ROOT / "hardware/sim/tb_ramp_math.sv")], OUT)
        run("xelab.bat", ["tb_ramp_math", "-s", "ramp_math", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["ramp_math", "-runall"], OUT)
        assert "RAMP_MATH_PASS vectors=65536 " in log and "Fatal:" not in log
        report.update(success=True, vectors=65536, multiply_cycles=3, direct_cycles=1, reset_positions=4,
                      limit="Ramp arithmetic only; pending/hold selection, decode refresh and IRQ delivery remain controller responsibilities")
        print("RAMP_MATH_COMPONENT_PASS vectors=65536")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
