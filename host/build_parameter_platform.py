"""Generate and validate the three-port parameter board platform; no bitstream claim."""
import json
from pathlib import Path
import zipfile
from test_filter_tva import run

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/parameter-platform"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_board_platform_generation", success=False, hardware_verified=False, bitstream=False)
    try:
        log = run("vivado.bat", ["-mode", "batch", "-nojournal", "-source", str(ROOT / "hardware/board/parameter_platform.tcl")], OUT)
        assert "SC88_PARAMETER_PLATFORM_COMPLETE" in log
        with zipfile.ZipFile(OUT / "sc88-platform.xsa") as archive:
            names = archive.namelist()
            assert any(name.endswith(".hwh") for name in names) and not any(name.endswith(".bit") for name in names)
        report.update(success=True, masters=["M_WAVE/HP0", "M_BLOCK/HP1", "M_AUDIO/HP2"], control_base="0x43c00000",
                      limitation="Validated block design and hardware handoff only; synthesis, routing, bitstream and hardware remain unverified")
        print(json.dumps(report))
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
