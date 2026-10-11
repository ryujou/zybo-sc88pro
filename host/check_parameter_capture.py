"""Compare captured PL records and the PS-returned PCM with fixed software assertions."""
import argparse
import json
from pathlib import Path
import struct


def compare(capture, reference):
    meta = json.loads((reference / "expected.json").read_text(encoding="utf-8"))
    first, frames = meta["first_frame"], meta["frames"]
    raw = (reference / "expected-results.bin").read_bytes()
    pcm = (reference / "expected-dry89.pcm").read_bytes()
    actual = capture.read_bytes()
    assert len(raw) == frames * 322 * 8 and len(pcm) == frames * 8
    assert len(actual) == frames * 323 * 8, "Capture length differs"
    records = 0
    for index in range(frames):
        expected = raw[index * 322 * 8:(index + 1) * 322 * 8]
        observed = actual[index * 323 * 8:(index + 1) * 323 * 8]
        frame, count = struct.unpack_from("<QQ", expected)
        assert frame == first + index and 64 <= count <= 320, "Invalid reference frame"
        assert observed[:16] == expected[:16], f"Frame/count differs at absolute frame {frame}"
        assert observed[16:24] == pcm[index * 8:(index + 1) * 8], f"Returned stereo PCM differs at absolute frame {frame}"
        for word in range(count):
            assert observed[24 + word * 8:32 + word * 8] == expected[16 + word * 8:24 + word * 8], \
                f"PL record differs at absolute frame {frame}, word {word}"
        records += count
    return dict(song=meta["song"], first_frame=first, frames=frames, records=records,
                stereo_samples=frames * 2, errors=0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=Path)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = dict(scope="parameter_raw_results_and_returned_PCM_comparison", success=False,
                  hardware_verified=False, limitation="File comparison only; matching JTAG and runtime evidence is required for hardware acceptance.")
    output = args.output or args.capture.with_suffix(".comparison.json")
    try:
        report.update(compare(args.capture, args.reference), success=True)
        print(json.dumps(report))
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
