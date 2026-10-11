"""Actual board top AXI-Lite control and independent input/audio DMA reset drain."""
import json
from pathlib import Path
import re
import shutil
from test_parameter_voice import RTL
from test_filter_tva import run, VIVADO

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-board-control"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_board_control_integration", success=False, hardware_verified=False)
    try:
        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", OUT / "xp3_interpolation.mem")
        names = RTL + ["pcm_mixer", "pcm_frame_fifo", "pcm_sample_fetcher", "pcm_sample_cache", "pcm_parameter_dma", "pcm_parameter_voice_scheduler"]
        sources = [ROOT / "hardware/rtl" / (name + ".sv") for name in names]
        xpm = VIVADO.parent / "data/ip/xpm"
        sources += [xpm / name / "hdl" / (name + ".sv") for name in ["xpm_cdc", "xpm_memory", "xpm_fifo"]]
        names = ["pcm_parameter_commands", "pcm_parameter_results", "pcm_i2s", "pcm_audio_bridge", "pcm_parameter_synth",
                 "pcm_axi_control", "pcm_parameter_registers", "pcm_block_dma", "pcm_block_queue", "pcm_transport", "pcm_return_audio", "pcm_parameter_board"]
        sources += [ROOT / "hardware/board" / (name + ".sv") for name in names]
        sources += [ROOT / "hardware/sim/tb_parameter_board.sv", VIVADO.parent / "data/verilog/src/glbl.v"]
        run("xvlog.bat", ["--sv", *map(str, sources)], OUT)
        run("xelab.bat", ["tb_parameter_board", "glbl", "-s", "parameter_board", "--debug", "typical", "-L", "unisims_ver"], OUT)
        log = run("xsim.bat", ["parameter_board", "-runall"], OUT)
        result = re.search(r"PARAMETER_BOARD_PASS accesses=(\d+) independent_DMA=1 reset_drain=1", log)
        assert result and "Fatal:" not in log and "Error:" not in log
        report.update(success=True, accesses=int(result[1]), independent_DMA=True, reset_drain=True,
                      limitation="Control and outstanding-bus drain only; not complete MIDI playback or board implementation evidence")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
