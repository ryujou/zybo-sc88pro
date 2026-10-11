"""32-frame startup and final I2S drain using actual XPM CDC and FIFO models."""
import json
from pathlib import Path
from test_filter_tva import run, VIVADO

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-audio-bridge"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_audio_CDC", success=False, hardware_verified=False)
    try:
        xpm = VIVADO.parent / "data/ip/xpm"
        sources = [xpm / name / "hdl" / (name + ".sv") for name in ["xpm_cdc", "xpm_memory", "xpm_fifo"]]
        sources += [ROOT / "hardware/board" / name for name in ["pcm_i2s.sv", "pcm_audio_bridge.sv"]]
        sources += [ROOT / "hardware/sim/tb_audio_bridge.sv", VIVADO.parent / "data/verilog/src/glbl.v"]
        run("xvlog.bat", ["--sv", *map(str, sources)], OUT)
        run("xelab.bat", ["tb_parameter_audio_bridge", "glbl",
                          "-s", "parameter_audio_bridge", "--debug", "typical", "-L", "unisims_ver"], OUT)
        log = run("xsim.bat", ["parameter_audio_bridge", "-runall"], OUT)
        assert "AUDIO_BRIDGE_PASS checks=11 full_depth=33 pause_resume=1 reset_positions=8 due_order=1 finish=1" in log
        assert "Fatal:" not in log and "Error:" not in log
        report.update(success=True, checks=11, reset_positions=8, startup_frames=32,
                      fifo_storage_depth=32, fifo_effective_depth=33, final_I2S_drain=True)
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
