"""Separate input/audio descriptor banks and synthesis/audio start controls."""
import json
from pathlib import Path
import re
from test_filter_tva import run

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-registers"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_board_registers", success=False, hardware_verified=False)
    try:
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/board/pcm_parameter_registers.sv"),
                          str(ROOT / "hardware/sim/tb_parameter_registers.sv")], OUT)
        run("xelab.bat", ["tb_parameter_registers", "-s", "parameter_registers", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["parameter_registers", "-runall"], OUT)
        result = re.search(r"PARAMETER_REGISTERS_PASS checks=(\d+)", log)
        assert result and "Fatal:" not in log
        report.update(success=True, accesses=int(result[1]))
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
