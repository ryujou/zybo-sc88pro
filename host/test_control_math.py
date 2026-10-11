"""Check every 18-bit pitch and combinedAmp boundaries against pinned C++ helpers."""
import json
import shutil
import subprocess

from test_filter_tva import ROOT, REFERENCE, rows, run

OUT = ROOT / "build/verification/phase-02-rtl/control-math"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="control_math_component", success=False, hardware_verified=False)
    try:
        table = ROOT / "hardware/rtl/xp3_pitch.mem"
        actual = [int(word, 16) for word in table.read_text(encoding="ascii").split()]
        expected = [int(row["mantissa"]) for row in rows(REFERENCE / "golden/pitch-table.csv")]
        assert len(actual) == 256 and actual == expected
        shutil.copyfile(table, OUT / table.name)
        with (OUT / "reference-build.log").open("w", encoding="utf-8") as log:
            subprocess.run(["pwsh", "-NoProfile", "-File", str(ROOT / "scripts/build_voice_reference.ps1")], stdout=log, stderr=subprocess.STDOUT, check=True)
        reference = subprocess.run([str(ROOT / "build/voice-reference/Release/sc88_control_vectors.exe"), str(OUT / "vectors.txt")], capture_output=True, text=True, check=True)
        assert "CONTROL_VECTORS_COMPLETE count=294912" in reference.stdout
        (OUT / "reference.log").write_text(reference.stdout, encoding="utf-8")
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/rtl/xp3_control_math.sv"), str(ROOT / "hardware/sim/tb_control_math.sv")], OUT)
        run("xelab.bat", ["tb_control_math", "-s", "control_math", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["control_math", "-runall"], OUT)
        assert "CONTROL_MATH_PASS vectors=294912 " in log and "Fatal:" not in log
        report.update(success=True, pitch_values=262144, combined_amp_values=32768, cycles=2, reset_positions=3)
        print("CONTROL_MATH_COMPONENT_PASS vectors=294912")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
