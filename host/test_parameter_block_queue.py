"""Check current command addresses and variable-Voice block result sizes."""
import json
from pathlib import Path
from test_filter_tva import run

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-block-queue"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_DMA_block_queue", success=False, hardware_verified=False)
    try:
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/board/pcm_block_queue.sv"),
                          str(ROOT / "hardware/sim/tb_block_queue.sv")], OUT)
        run("xelab.bat", ["tb_parameter_block_queue", "-s", "parameter_block_queue", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["parameter_block_queue", "-runall"], OUT)
        assert "BLOCK_QUEUE_PASS checks=123 blocks=8 read_ahead=1 cpu_reuse=1" in log and "Fatal:" not in log
        report.update(success=True, checks=123, blocks=8, read_ahead=True, cpu_reuse=True)
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
