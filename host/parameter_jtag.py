"""Check the parameter board bundle; --load programs the selected Zybo with USB Host disabled."""
import os
import argparse
import json
from pathlib import Path
import subprocess
import zipfile
from test_board_implementation import inspect

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--load", action="store_true")
    parser.add_argument("--cable-serial", default="")
    parser.add_argument("--capture", action="store_true", help="Select the diagnostic ELF built with --capture-first")
    args = parser.parse_args()
    if args.load and not args.cable_serial:
        parser.error("--load requires --cable-serial")
    board, ps = OUT / "board", OUT / ("parameter-capture-ps" if args.capture else "parameter-ps")
    assert json.loads((board / "summary.json").read_text(encoding="utf-8"))["success"], "Board implementation must pass"
    inspect(board)
    firmware = json.loads((ps / "summary.json").read_text(encoding="utf-8"))
    assert firmware["success"] and firmware["xsa_contains_bit"], "Rebuild the ELF from the completed bit-inclusive XSA"
    assert bool(firmware.get("capture")) == args.capture, "Diagnostic capture selection differs from the ELF build"
    assert Path(firmware["xsa"]).resolve() == (board / "sc88.xsa").resolve()
    with zipfile.ZipFile(board / "sc88.xsa") as archive:
        init = [name for name in archive.namelist() if name.rsplit("/", 1)[-1] == "ps7_init.tcl"]
        assert len(init) == 1 and archive.read(init[0]) == (ps / "ps7_init.tcl").read_bytes()
    mode = "load" if args.load else "check"
    command = [str(Path(os.environ["VITIS_ROOT"]) / "bin/xsct.bat"), ROOT / "scripts/parameter_jtag.tcl",
               board / "sc88.xsa", board / "sc88.bit", ps / "parameter_player.elf", ps / "ps7_init.tcl",
               mode, args.cable_serial or "OFFLINE"]
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    (ps / ("jtag-" + mode + ".log")).write_text(result.stdout + result.stderr, encoding="utf-8")
    result.check_returncode()
    marker = "SC88_PARAMETER_JTAG_STARTED" if args.load else "SC88_PARAMETER_JTAG_CHECK_COMPLETE"
    assert marker in result.stdout
    print(result.stdout.strip())


if __name__ == "__main__":
    main()
