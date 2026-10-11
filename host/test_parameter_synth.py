"""Cold Voice integration through descriptors, ordered results, mock PS return and I2S."""
import json
from pathlib import Path
import re
import shutil
from test_parameter_voice import RTL
from test_filter_tva import run, VIVADO

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-synth"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_synth_integration", success=False, hardware_verified=False)
    try:
        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", OUT / "xp3_interpolation.mem")
        names = RTL + ["pcm_mixer", "pcm_frame_fifo", "pcm_sample_fetcher", "pcm_sample_cache", "pcm_parameter_dma", "pcm_parameter_voice_scheduler"]
        sources = [ROOT / "hardware/rtl" / (name + ".sv") for name in names]
        xpm = VIVADO.parent / "data/ip/xpm"
        sources += [xpm / name / "hdl" / (name + ".sv") for name in ["xpm_cdc", "xpm_memory", "xpm_fifo"]]
        sources += [ROOT / "hardware/board" / (name + ".sv") for name in ["pcm_parameter_commands", "pcm_parameter_results", "pcm_i2s", "pcm_audio_bridge", "pcm_parameter_synth"]]
        sources += [ROOT / "hardware/sim/tb_parameter_synth.sv", VIVADO.parent / "data/verilog/src/glbl.v"]
        run("xvlog.bat", ["--sv", *map(str, sources)], OUT)
        cases = []
        for top, frames in [("tb_parameter_synth", 96), ("tb_parameter_synth_short", 1)]:
            run("xelab.bat", [top, "glbl", "-s", top, "--debug", "typical", "-L", "unisims_ver"], OUT)
            log = run("xsim.bat", [top, "-runall"], OUT)
            (OUT / (top + ".log")).write_text(log, encoding="utf-8")
            result = re.search(r"PARAMETER_SYNTH_PASS frames=(\d+) bursts=(\d+) max_core=(\d+) max_due=(\d+)", log)
            assert result and "Fatal:" not in log and "Error:" not in log
            assert int(result[1]) == int(result[2]) == frames
            assert int(result[3]) <= 3125 and int(result[4]) <= 3125
            cases.append(dict(frames=frames, bursts=int(result[2]), max_core_cycles=int(result[3]), max_due_cycles=int(result[4])))
        report.update(success=True, cases=cases,
                      limitation="Cold unreleased Voices and mock PS result/return service; not real MIDI audio, block DMA/MMIO or board evidence")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
