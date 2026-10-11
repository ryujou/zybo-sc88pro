"""Full parameter board implementation, including both ILAs and three PS HP ports."""
import argparse
import json
from pathlib import Path
import zipfile
from test_filter_tva import run
from test_board_implementation import inspect

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/board"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspect-only", action="store_true")
    reuse = parser.add_mutually_exclusive_group()
    reuse.add_argument("--resume", action="store_true", help="Resume the existing platform; sources must be unchanged")
    reuse.add_argument("--rebuild-shell", action="store_true", help="Rebuild board RTL and retain the unchanged six-part parameter core and platform IP")
    reuse.add_argument("--finalize", action="store_true", help="Recheck and export the routed checkpoint; RTL and platform must be unchanged")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_full_Zybo_PS_PL_with_ILAs", success=False, hardware_verified=False)
    (OUT / "summary.json").write_text(json.dumps(report), encoding="utf-8")
    try:
        if not args.inspect_only:
            command = ["-mode", "batch", "-nojournal", "-source", str(ROOT / "hardware/board/parameter_build.tcl")]
            if args.resume:
                command += ["-tclargs", "resume"]
            elif args.rebuild_shell:
                command += ["-tclargs", "shell"]
            elif args.finalize:
                command += ["-tclargs", "finalize"]
            log = run("vivado.bat", command, OUT)
            assert "SC88_PARAMETER_BOARD_ARTIFACTS_COMPLETE" in log
            # XSA export regenerates the bitstream header; publish that exact bundle member.
            with zipfile.ZipFile(OUT / "sc88.xsa") as archive:
                bits = [name for name in archive.namelist() if name.endswith(".bit")]
                assert len(bits) == 1
                (OUT / "sc88.bit").write_bytes(archive.read(bits[0]))
        report.update(success=True, device=inspect(OUT))
        print(json.dumps(report))
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
