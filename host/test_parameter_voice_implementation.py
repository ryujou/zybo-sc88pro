"""Route the complete parameter Voice core at 100 MHz on XC7Z010."""
import json
from test_filter_tva import ROOT, run
from test_voice_units_implementation import inspect_reports

OUT = ROOT / "build/verification/offline-player/phase-02/voice-implementation"


def inspect():
    core = inspect_reports(["xp3_parameter_voice"], OUT)["xp3_parameter_voice"]
    assert core["LUT"] <= 12000 and core["FF"] <= 16000 and core["DSP"] <= 32 and core["BRAM18"] + 2*core["BRAM36"] <= 24, f"Parameter Voice resource budget exceeded: {core}"
    return core


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_voice_core_out_of_context", success=False, hardware_verified=False,
                  limit="Internal registered paths; external PS/DDR and board timing await integration")
    try:
        source = (ROOT / "hardware/rtl/xp3_parameter_voice.sv").read_text(encoding="utf-8")
        assert not any(name in source for name in ["xp3_ramp_math", "xp3_control_math", "xp3_source_control", "xp3_ramp_service"])
        log = run("vivado.bat", ["-mode", "batch", "-source", str(ROOT / "hardware/synth/parameter_voice.tcl"), "-notrace"], OUT)
        assert "VOICE_IMPLEMENTATION_COMPLETE" in log
        report.update(success=True, core=inspect())
        print(json.dumps(report), flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
