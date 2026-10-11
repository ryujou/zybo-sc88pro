"""Implement Voice components and inspect routed resource/internal timing reports."""
import json
import re

from test_filter_tva import ROOT, run

OUT = ROOT / "build/verification/phase-02-rtl/units-implementation"
TOPS = ["xp3_filter_tva", "xp3_interpolate", "xp3_voice_state", "xp3_pair_filter", "xp3_ramp_math", "xp3_control_math", "xp3_ramp_service", "xp3_wave_source", "xp3_source_control"]


def inspect_reports(tops=TOPS, directory=OUT):
    result = {}
    for top in tops:
        utilization = (directory / f"{top}_utilization.rpt").read_text(encoding="utf-8")
        timing = (directory / f"{top}_timing.rpt").read_text(encoding="utf-8")
        assert "Design State : Routed" in utilization and "xc7z010clg400-1" in utilization
        row = re.search(r"^\| " + top + r"\s*\|\s*\(top\)\s*\|([^\n]+)", utilization, re.M)
        assert row, f"Missing utilization for {top}"
        values = [int(value.strip()) for value in row.group(1).split("|") if value.strip()]
        assert len(values) == 8
        header = re.search(r"WNS\(ns\).*?\n\s*-.*?\n\s*([^\n]+)", timing)
        assert header, f"Missing timing for {top}"
        times = list(map(float, header.group(1).split()))
        assert len(times) == 12
        assert all(times[index] >= 0 for index in [0, 4, 8]), f"Setup/hold/pulse-width violation: {top}"
        assert all(times[index] == 0 for index in [1, 2, 5, 6, 9, 10]), f"Failing timing endpoints: {top}"
        assert "checking no_clock (0)" in timing and "checking unconstrained_internal_endpoints (0)" in timing
        drc = (directory / f"{top}_drc.rpt").read_text(encoding="utf-8")
        assert not re.search(r"\|\s*(?:Error|Critical Warning)\s*\|", drc), f"DRC error: {top}"
        result[top] = dict(LUT=values[0], FF=values[4], BRAM36=values[5], BRAM18=values[6], DSP=values[7],
                           WNS_ns=times[0], WHS_ns=times[4], WPWS_ns=times[8])
    if "xp3_voice_state" in result:
        assert result["xp3_voice_state"]["BRAM36"] * 2 + result["xp3_voice_state"]["BRAM18"] == 8
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="voice_components_out_of_context", success=False, hardware_verified=False,
                  limit="Internal registered paths only; module I/O delays, integrated Voice and board timing are not verified")
    try:
        log = run("vivado.bat", ["-mode", "batch", "-source", str(ROOT / "hardware/synth/voice_units.tcl"), "-notrace"], OUT)
        assert "VOICE_UNITS_IMPLEMENTATION_COMPLETE scope=components_only" in log
        report.update(success=True, components=inspect_reports())
        print("VOICE_COMPONENTS_IMPLEMENTATION_PASS")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
