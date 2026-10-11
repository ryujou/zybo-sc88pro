"""Exercise PS-return audio DDR reads, ownership, backpressure and bus faults."""
import json
from pathlib import Path
from test_filter_tva import run

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/return-audio"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="PS_return_audio_DMA", success=False, hardware_verified=False)
    try:
        sources = [ROOT / "hardware/board" / n for n in ["pcm_block_dma.sv", "pcm_return_audio.sv"]]
        sources.append(ROOT / "hardware/sim/tb_return_audio.sv")
        run("xvlog.bat", ["--sv", *map(str, sources)], OUT)
        run("xelab.bat", ["tb_return_audio", "-s", "return_audio", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["return_audio", "-runall"], OUT)
        assert "RETURN_AUDIO_STREAM frames=117 blocks=8" in log
        assert "RETURN_AUDIO_PASS checks=3 negatives=10" in log and "Fatal:" not in log
        report.update(success=True, frames=117, blocks=8, checks=3, negatives=10,
                      limitation="AXI bus model; real PS Cache and DDR remain unverified")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
