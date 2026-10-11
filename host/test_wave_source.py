"""Source-stage component checks, including exact ordered ROM transactions and stalls."""
import itertools
import json
import re
import shutil

from test_filter_tva import ROOT, REFERENCE, rows, run

OUT = ROOT / "build/verification/phase-02-rtl/wave-source"


def write_vectors(stream, directory, trace=False):
    prefix = "voice-" if trace else ""
    reads = iter(itertools.groupby(rows(directory / f"{prefix}rom-reads.csv"), lambda r: (int(r["frame"]), int(r["voice"]))))
    stages = iter((r for r in rows(directory / f"{prefix}stages.csv") if r["stage"] == "interpolation"))
    read_key, read_rows = next(reads, (None, []))
    stage = next(stages, None)
    count = 0
    for pre, post in zip(rows(directory / f"{prefix}source-before.csv"), rows(directory / f"{prefix}source-after.csv"), strict=True):
        key = (int(pre["frame"]), int(pre["voice"]))
        assert key == (int(post["frame"]), int(post["voice"]))
        rom = list(read_rows) if read_key == key else []
        if read_key == key:
            read_key, read_rows = next(reads, (None, []))
        due = stage is not None and key == (int(stage["frame"]), int(stage["voice"]))
        sample = int(stage["b"]) if due else 0
        if due:
            stage = next(stages, None)
        def packed_fifo(row):
            return format(sum(int(row[f"waveCircularBuffer_0800[{i}]"]) << (12*i) for i in range(8)), "024x")
        initial = [pre[name] for name in ["sampleClock", "voiceIndex", "runtimeCache.runtimePhase", "runtimeCache.waveSampleFormat",
                   "waveControl_0000", "sampleCurrent_0100", "sampleLoop_0200", "sampleEnd_0300", "waveFetchState_0400",
                   "dpcmAccumulator_0c00", "pitchIncrement_0d00", "addressFraction_0e00", "playbackStateConfig_1000"]]
        initial += [packed_fifo(pre), int(pre["descriptor"]) & 1, pre["physical16"], pre["bankShift"],
                    pre["irqStatus"], pre["irqConfigMask"], pre["interrupt"], pre["acceptedThisFrame"], pre["irqBlockedEvent"]]
        expected = [post[name] for name in ["waveControl_0000", "sampleCurrent_0100", "waveFetchState_0400", "dpcmAccumulator_0c00",
                    "addressFraction_0e00", "playbackStateConfig_1000"]]
        expected += [packed_fifo(post), post["runtimeCache.runtimePhase"], post["runtimeCache.waveSampleFormat"], sample, int(due),
                     post["irqStatus"], post["interrupt"], post["acceptedThisFrame"], post["irqBlockedEvent"]]
        assert len(initial) == 22 and len(expected) == 15 and len(rom) <= 32
        stream.write(" ".join(map(str, initial + expected + [len(rom)])) + "\n")
        for read in rom:
            stream.write(f"{read['chip_select']} {read['physical_address']} {read['value']}\n")
        count += 1
    assert read_key is None and stage is None, f"Unconsumed source observations: {directory}"
    return count


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="wave_source_component", success=False, hardware_verified=False)
    try:
        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", OUT / "xp3_interpolation.mem")
        contract = json.loads((ROOT / "reference/phase2-contract.json").read_text(encoding="utf-8"))
        counts = {}
        with (OUT / "vectors.txt").open("w", encoding="utf-8", newline="\n") as stream:
            for name in contract["cases"]:
                counts[name] = write_vectors(stream, REFERENCE / "golden" / name)
            counts["trace-piano"] = write_vectors(stream, REFERENCE / "trace-piano", True)
        files = ["hardware/rtl/xp3_sample_pkg.sv", "hardware/rtl/xp3_interpolate.sv", "hardware/rtl/xp3_wave_source.sv", "hardware/sim/tb_wave_source.sv"]
        run("xvlog.bat", ["--sv", *[str(ROOT / f) for f in files]], OUT)
        run("xelab.bat", ["tb_wave_source", "-s", "wave_source", "--debug", "typical"], OUT)
        log = run("xsim.bat", ["wave_source", "-runall"], OUT)
        match = re.search(r"WAVE_SOURCE_PASS vectors=(\d+) worst_cycles=(\d+) reads=(\d+)", log)
        assert match and int(match[1]) == sum(counts.values()) and "Fatal:" not in log
        (OUT / "positive.log").write_text(log, encoding="utf-8")
        assert "SOURCE_RESET_PASS checks=128" in log
        nominal = run("xsim.bat", ["wave_source", "-runall", "-testplusarg", "nominal"], OUT)
        (OUT / "nominal.log").write_text(nominal, encoding="utf-8")
        nominal_match = re.search(r"WAVE_SOURCE_PASS vectors=(\d+) worst_cycles=(\d+) reads=(\d+)", nominal)
        assert nominal_match and int(nominal_match[1]) == sum(counts.values()) and "Fatal:" not in nominal
        assert nominal_match[3] == match[3] and "SOURCE_RESET_PASS checks=128" in nominal
        try:
            negative = run("xsim.bat", ["wave_source", "-runall", "-testplusarg", "damage_rom"], OUT)
        except RuntimeError:
            negative = (OUT / "xsim.bat.log").read_text(encoding="utf-8")
        (OUT / "negative-rom.log").write_text(negative, encoding="utf-8")
        assert "SOURCE_DIFFERENCE" in negative and "WAVE_SOURCE_PASS" not in negative
        report.update(success=True, vectors=sum(counts.values()), cases=counts, worst_stalled_cycles=int(match[2]), rom_reads=int(match[3]),
                      worst_nominal_cycles=int(nominal_match[2]), reset_positions=128, rom_byte_negative_detected=True, limit="Observed source-stage inputs; no independent full Voice progression or full-core cycle claim")
        print(f"WAVE_SOURCE_COMPONENT_PASS vectors={sum(counts.values())} reads={match[3]}")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
