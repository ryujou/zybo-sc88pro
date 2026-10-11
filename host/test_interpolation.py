"""Check hand-written interpolation RTL with pinned XP stage stimuli and table."""
import json
import shutil

from test_filter_tva import ROOT, REFERENCE, rows, run, vectors

OUT = ROOT / "build/verification/phase-02-rtl/interpolation"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="interpolation_component", success=False, hardware_verified=False)
    try:
        table = ROOT / "hardware/rtl/xp3_interpolation.mem"
        actual = [int(word, 16) for word in table.read_text(encoding="ascii").split()]
        expected = [int(row["coefficient"]) for row in rows(REFERENCE / "golden/interpolation-table.csv")]
        assert len(actual) == 384 and actual == expected, "RTL interpolation table differs from fixed reference"
        shutil.copyfile(table, OUT / table.name)
        contract = json.loads((ROOT / "reference/phase2-contract.json").read_text(encoding="utf-8"))
        counts = {}
        with (OUT / "vectors.txt").open("w", encoding="utf-8", newline="\n") as stream:
            for name in contract["cases"]:
                counts[name] = vectors(stream, REFERENCE / "golden" / name, stage_kind="interpolation")
            counts["trace-piano"] = vectors(stream, REFERENCE / "trace-piano", trace=True, stage_kind="interpolation")
        assert sum(counts.values()) > 0
        files = [ROOT / "hardware/rtl/xp3_sample_pkg.sv", ROOT / "hardware/rtl/xp3_interpolate.sv", ROOT / "hardware/sim/tb_interpolate.sv"]
        run("xvlog.bat", ["--sv", *map(str, files)], OUT)
        run("xelab.bat", ["tb_interpolate", "-s", "interpolate", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["interpolate", "-runall"], OUT)
        assert f"INTERPOLATE_PASS vectors={sum(counts.values())} " in log and "Fatal:" not in log, "RTL assertion failed or completion missing"
        (OUT / "positive.log").write_text(log, encoding="utf-8")
        damaged = actual.copy()
        damaged[0] ^= 1
        try:
            (OUT / table.name).write_text("".join(f"{word:03x}\n" for word in damaged), encoding="ascii")
            try:
                negative = run("xsim.bat", ["interpolate", "-runall"], OUT)
            except RuntimeError:
                negative = (OUT / "xsim.bat.log").read_text(encoding="utf-8")
            (OUT / "negative-coefficient.log").write_text(negative, encoding="utf-8")
            assert "DIFFERENCE vector=" in negative and "INTERPOLATE_PASS" not in negative, "Coefficient corruption was not detected"
        finally:
            shutil.copyfile(table, OUT / table.name)
        report.update(success=True, vectors=sum(counts.values()), cases=counts, cycles=7, reset_positions=8,
                      coefficient_negative_detected=True,
                      limit="Stage-unit inputs use observed state; full Voice progression remains unverified")
        print(f"INTERPOLATION_COMPONENT_PASS vectors={sum(counts.values())}")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
