"""XSim state-RAM address, masked-write and reset verification."""
import json

from test_filter_tva import ROOT, run

OUT = ROOT / "build/verification/phase-02-rtl/voice-state"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="voice_state_component", success=False, hardware_verified=False)
    try:
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/rtl/xp3_voice_state.sv"), str(ROOT / "hardware/sim/tb_voice_state.sv")], OUT)
        run("xelab.bat", ["tb_voice_state", "-s", "voice_state", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["voice_state", "-runall"], OUT)
        assert "VOICE_STATE_PASS rows=512 banks=8 reset_cycles=512" in log and "Fatal:" not in log
        report.update(success=True, rows=512, banks=8, reset_cycles=512)
        print("VOICE_STATE_COMPONENT_PASS")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
