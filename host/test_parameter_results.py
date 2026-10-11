"""Check ordered DMA results with per-frame Voice counts and bounded metadata."""
import json
import re
from pathlib import Path
from test_filter_tva import run

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-results"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_result_component", success=False, hardware_verified=False)
    try:
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/board/pcm_parameter_results.sv"),
                          str(ROOT / "hardware/sim/tb_parameter_results.sv")], OUT)
        run("xelab.bat", ["tb_parameter_results", "-s", "parameter_results", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["parameter_results", "-runall"], OUT)
        stream = re.search(r"PARAMETER_RESULT_STREAM frames=(\d+) words=(\d+)", log)
        result = re.search(r"PARAMETER_RESULTS_PASS checks=(\d+) negatives=(\d+)", log)
        assert stream and result and "Fatal:" not in log, "Parameter result simulation failed"
        assert tuple(map(int, result.groups())) == (3, 6)
        assert int(stream[2]) == sum(((n * 17 % 64) + 1) * 4 + 64 for n in range(40))
        report.update(success=True, frames=int(stream[1]), words=int(stream[2]), checks=3, negatives=6,
                      limit="Synthetic result stream; no audio, DMA memory or board evidence")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
