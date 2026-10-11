"""Four-Voice local IRQ/hold progression against the untouched XP boundary probe."""
from collections import defaultdict
import json
import re
import shutil
import struct

import phase0 as p0
import offline_parameter_format as fmt
from test_filter_tva import ROOT, rows, run
from test_parameter_voice import BASE, RTL, hooks

OUT = BASE / "voice-irq"


def validate_reference(case, directory):
    original = directory / "original"
    p0.run([str(ROOT / "build/offline-player/Release/sc88_offline_irq_0.exe"), str(case), str(original)], directory / "original.log")
    words = struct.unpack("<" + "Q"*(202*64), (original / "reference.state").read_bytes())
    for index, row in enumerate(rows(directory / "expected.csv")):
        actual = [int(row[key]) for key in ["sampleClock", "interrupt", "irqStatus", "irqBlockedEvent", "irqConfigMask"]]
        expected = list(words[index*202:index*202+5])
        for voice in range(4):
            prefix = f"voice[{voice}]."
            for field in fmt.FIELD_NAMES:
                value = int(row[prefix+field])
                if field in fmt.FIELD_NAMES[6:11]:
                    value &= ~0x20000
                actual.append(value)
            tail = [*fmt.FIELD_NAMES[6:11], "waveControl_0000", "sampleCurrent_0100", "sampleLoop_0200", "sampleEnd_0300", "waveFetchState_0400",
                    *[f"waveCircularBuffer_0800[{i}]" for i in range(8)], "dpcmAccumulator_0c00", "addressFraction_0e00", "playbackStateConfig_1000", "tvaGain_2700",
                    "filterBp_2800", "filterLp_2900", "filterOutput_2a00", "runtimeCache.runtimePhase", "runtimeCache.waveSampleFormat"]
            actual += [int(row[prefix+key]) for key in tail]
        expected += words[index*202+6:(index+1)*202]
        assert actual == expected, (case, index, "Parameter hook observation differs from pristine XP")
    # The Phase 1 observation exporter uses the same original four-Voice fixtures.
    p0.run([str(ROOT / "build/offline-player/Release/sc88_offline_irq_1.exe"), str(case), str(original)], directory / "export.log")
    changed = {}
    for row in rows(directory / "parameters.csv"):
        if int(row["mask"]) or int(row["terminal"]) >= 0:
            changed[(int(row["frame"]), int(row["voice"]), int(row["stage"]))] = [int(row["mask"]), int(row["terminal"]), [int(row[f"value{i}"]) for i in range(22)]]
    records = {}
    for event, payload in fmt.events(original / "song.scp", p0.LOCK["commit"]):
        frame, _, kind, stage, _, voice, mask, _ = event
        if kind not in [6, 7]:
            continue
        packet = records.setdefault((frame, voice, stage), [0, -1, [0]*22])
        if kind == 6:
            packet[0] = mask
            values = iter(struct.unpack(f"<{mask.bit_count()}I", payload))
            for i in range(22):
                if mask & (1 << i):
                    packet[2][i] = next(values)
        else:
            packet[1] = payload[0]
    assert changed == records, (case, "SC88PAR1 differs from original control hooks")


def vectors(reference):
    fields = json.loads((ROOT / "reference/phase2-rtl-contract.json").read_text(encoding="utf-8"))["state_fields"]
    commands = 0
    with (OUT / "vectors.txt").open("w", encoding="utf-8", newline="\n") as output:
        def emit(*values):
            output.write(" ".join(map(str, values))+"\n")
        for case in range(22):
            directory = reference / f"irq_{case}"
            validate_reference(case, directory)
            initial = next(rows(directory / "initial.csv"))
            emit(0, initial["irqStatus"], initial["irqConfigMask"], initial["interrupt"], 0, 1)
            for voice in range(4):
                for field in fields:
                    emit(1, voice, field["word"], initial[f"voice[{voice}].{field['name']}"])
            reads = defaultdict(list)
            stages = defaultdict(list)
            samples = {}
            parameters = hooks(directory)
            for row in rows(directory / "rom-reads.csv"):
                reads[int(row["frame"]), int(row["voice"])].append(row)
            for order, row in enumerate(rows(directory / "stages.csv")):
                row["sequence"] = order
                key = int(row["frame"]), int(row["voice"])
                if row["stage"] == "interpolation":
                    samples[key] = int(row["b"])
                else:
                    stages[key].append(row)
            for row in rows(directory / "commands.csv"):
                frame, voice, paired = int(row["frame"]), int(row["command_voice"]), int(row["pair"])
                if voice == 0 and frame and frame % 8 == 0:
                    emit(4, 0)
                voices = range(voice, voice+1+paired)
                numeric = []
                rom = []
                packets = []
                for lane in voices:
                    numeric.extend(stages.pop((frame, lane), []))
                    rom.extend(reads.pop((frame, lane), []))
                numeric.sort(key=lambda stage: stage["sequence"])
                kept = []
                for packet in parameters[frame]:
                    (packets if int(packet[0]) in voices else kept).append(packet)
                parameters[frame] = kept
                emit(10, voice)
                emit(8, len(numeric))
                for stage in numeric:
                    emit(int(stage["stage"] == "tva"), stage["voice"], *[stage[key] for key in "abcdefgh"])
                emit(9, len(packets))
                for packet in packets:
                    emit(frame, *packet)
                due = sum((int((frame, lane) in samples) << (lane-voice)) for lane in voices)
                emit(2, frame, paired, row["irqStatus"], row["interrupt"], row["irqBlockedEvent"], due, samples.pop((frame, voice), 0),
                     samples.pop((frame, voice+1), 0) if paired else 0, row[f"voice[{voice}].filterOutput_2a00"],
                     row[f"voice[{voice+1}].filterOutput_2a00"] if paired else 0, len(rom))
                for read in rom:
                    emit(read["chip_select"], read["physical_address"], int(read["voice"])-voice, read["value"])
                for lane in voices:
                    for field in fields:
                        emit(3, lane, field["word"], row[f"voice[{lane}].{field['name']}"])
                commands += 1
            assert not reads and not stages and not samples and not any(parameters.values())
    return commands


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_four_voice_irq_boundaries", success=False, hardware_verified=False)
    try:
        reference = BASE / "parameter-reference/irq"
        p0.run([str(ROOT / "build/parameter-voice-reference/Release/sc88_parameter_irq_vectors.exe"), str(reference)], OUT / "reference.log")
        count = vectors(reference)
        shutil.copyfile(reference / "decoded-wave.bin", OUT / "decoded-wave.bin")
        shutil.copyfile(ROOT / "hardware/rtl/xp3_interpolation.mem", OUT / "xp3_interpolation.mem")
        run("xvlog.bat", ["--sv", *[str(ROOT / "hardware/rtl" / (name+".sv")) for name in RTL], str(ROOT / "hardware/sim/tb_parameter_voice.sv")], OUT)
        run("xelab.bat", ["tb_parameter_voice", "-s", "parameter_voice", "--debug", "typical"], OUT)
        for name, extra in [("nominal", []), ("stalls", ["-testplusarg", "stalls", "-testplusarg", "parameter_late"])]:
            log = run("xsim.bat", ["parameter_voice", "-runall", "-testplusarg", "pressure", "-testplusarg", "irq_boundary", *extra], OUT)
            (OUT / (name+".log")).write_text(log, encoding="utf-8")
            match = re.search(r"VOICE_SYNTHETIC_PASS cases=22 frames=(\d+) single_cycles=(\d+) pair_cycles=(\d+)", log)
            assert match and int(match[1]) == count and "Fatal:" not in log
            if name == "nominal":
                assert int(match[2]) <= 44 and int(match[3]) <= 88
            report[name] = dict(commands=count, single_cycles=int(match[2]), pair_cycles=int(match[3]))
        report.update(success=True, cases=22, frames=1408, compared_state_words_per_frame=201, original_reference_exact=True, phase1_binary_exact=True)
        print(json.dumps(report), flush=True)
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
