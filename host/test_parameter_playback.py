"""Exercise normal block DMA/MMIO/PS-return flow through the complete parameter board RTL."""
import json
from pathlib import Path
import re
import shutil
from test_parameter_voice import RTL
from test_filter_tva import run, VIVADO

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-playback"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_board_normal_DMA_playback", success=False, hardware_verified=False)
    try:
        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", OUT / "xp3_interpolation.mem")
        names = RTL + ["pcm_mixer", "pcm_frame_fifo", "pcm_sample_fetcher", "pcm_sample_cache", "pcm_parameter_dma", "pcm_parameter_voice_scheduler"]
        sources = [ROOT / "hardware/rtl" / (name + ".sv") for name in names]
        xpm = VIVADO.parent / "data/ip/xpm"
        sources += [xpm / name / "hdl" / (name + ".sv") for name in ["xpm_cdc", "xpm_memory", "xpm_fifo"]]
        names = ["pcm_parameter_commands", "pcm_parameter_results", "pcm_i2s", "pcm_audio_bridge", "pcm_parameter_synth",
                 "pcm_axi_control", "pcm_parameter_registers", "pcm_block_dma", "pcm_block_queue", "pcm_transport", "pcm_return_audio", "pcm_parameter_board"]
        sources += [ROOT / "hardware/board" / (name + ".sv") for name in names]
        sources += [ROOT / "hardware/sim/tb_parameter_board.sv", ROOT / "hardware/sim/tb_parameter_playback.sv",
                    VIVADO.parent / "data/verilog/src/glbl.v"]
        run("xvlog.bat", ["--sv", *map(str, sources)], OUT)
        cases = []
        for top, frames in [("tb_parameter_playback", 65), ("tb_parameter_playback_short", 1)]:
            run("xelab.bat", [top, "glbl", "-s", top, "--debug", "typical", "-L", "unisims_ver"], OUT)
            log = run("xsim.bat", [top, "-runall"], OUT)
            (OUT / (top + ".log")).write_text(log, encoding="utf-8")
            match = re.search(r"PARAMETER_PLAYBACK_PASS frames=(\d+) blocks=(\d+) accesses=(\d+) max_due=(\d+)", log)
            assert match and "Fatal:" not in log and "Error:" not in log
            assert int(match[1]) == frames and int(match[2]) == (frames + 15) // 16 and int(match[4]) <= 3125
            cases.append(dict(frames=frames, blocks=int(match[2]), accesses=int(match[3]), max_due_cycles=int(match[4])))
        report.update(success=True, cases=cases, limitation="Cold unreleased Voices, modeled DDR and PS; not real MIDI audio, Cortex-A9 timing or board evidence")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
