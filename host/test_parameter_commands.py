"""Phase 4 descriptor, credit and IRQ ordering component checks with a mock core."""
import json
import re
from pathlib import Path
from test_filter_tva import run

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-commands"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_command_component", success=False, hardware_verified=False)
    try:
        run("xvlog.bat", ["--sv", str(ROOT / "hardware/board/pcm_parameter_commands.sv"),
                          str(ROOT / "hardware/sim/tb_parameter_commands.sv")], OUT)
        run("xelab.bat", ["tb_parameter_commands", "-s", "parameter_commands", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["parameter_commands", "-runall"], OUT)
        stream = re.search(r"PARAMETER_COMMAND_STREAM frames=(\d+) ticks=(\d+) prefetch=(\d+) max_mock_due=(\d+)", log)
        result = re.search(r"PARAMETER_COMMANDS_PASS checks=(\d+) negatives=(\d+) resets=(\d+)", log)
        assert stream and result and "Fatal:" not in log, "Parameter command simulation failed"
        assert tuple(map(int, result.groups())) == (8, 15, 8)
        report.update(success=True, frames=int(stream[1]), due_ticks=int(stream[2]),
                      prefetched_while_busy=int(stream[3]), max_mock_due_cycles=int(stream[4]),
                      checks=int(result[1]), negatives=int(result[2]), resets=int(result[3]),
                      limit="Synthetic descriptor/mock core checks; not MIDI audio, DDR or board timing evidence")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
