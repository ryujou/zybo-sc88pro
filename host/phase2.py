"""Phase 2 Gate A: executable single-Voice numerical contract and pinned golden probes."""
import argparse
import csv
import json
import re
import subprocess

import phase0 as p0
from sc88_audio_compare import compare

ROOT = p0.ROOT
OUT = ROOT / "build/verification/phase-02"
CONTRACT = json.loads((ROOT / "reference/phase2-contract.json").read_text(encoding="utf-8"))
BIN = ROOT / "build/voice-reference/Release"


def rows(path):
    with path.open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        assert reader.fieldnames and len(reader.fieldnames) == len(set(reader.fieldnames)), f"Empty/duplicate CSV columns: {path}"
        for row in reader:
            assert None not in row and all(value is not None for value in row.values()), f"Truncated CSV row: {path}"
            yield row


def state_width(name):
    if not name.startswith("voice["):
        return {"frame":64,"sampleClock":64,"irqStatus":16,"irqConfigMask":16,"interrupt":1,"irqBlockedEvent":1}.get(name,8)
    member = name.split("].",1)[1]
    return CONTRACT["state_widths"][member.split("[",1)[0]]


def validate_states(path, count, start=0):
    active = 0
    last = start - 1
    columns = None
    for row in rows(path):
        assert int(row["frame"]) == last + 1, f"Non-contiguous frame: {path}"
        last += 1
        columns = list(row)
        for name, value in row.items():
            assert 0 <= int(value) < 1 << state_width(name), f"State outside declared width: {name} in {path}"
        active += any(int(value) for name,value in row.items() if name.endswith(".filterOutput_2a00"))
    assert last + 1 - start == count, f"Empty/truncated Voice vector: {path}"
    return {"frames":count,"columns":len(columns),"active_frames":active}


def semantic_checks(golden):
    state = lambda name:list(rows(golden / name / "expected.csv"))
    v = lambda row,name:int(row["voice[0]."+name])
    baseline = state("fce_dpcm")
    assert [v(row,"runtimeCache.runtimePhase") for row in baseline[:3]] == [2,3,4]
    assert all(v(row,"filterOutput_2a00") == 0 for row in baseline[:3])
    for name in ["silence","reserved_exponent","wave_halt","consumer_blocked","unmapped_cs","tva_zero"]:
        assert all(v(row,"filterOutput_2a00") == 0 for row in state(name)), f"Expected silent boundary: {name}"
    assert v(state("accumulator_wrap")[0],"dpcmAccumulator_0c00") == 123
    assert {v(row,"waveControl_0000") & 0x2000 for row in state("alternate_loop")} == {0,0x2000}
    assert all(v(row,"sampleCurrent_0100") == 0x40038 for row in state("zero_pitch")[3:])
    assert any(v(row,"sampleCurrent_0100") < 16 for row in state("address_wrap"))
    assert v(state("endpoint_hold")[-1],"sampleCurrent_0100") == 0x40038
    assert state("tva_reset_decay")[-1]["voice[0].tvaGain_2700"] == "1"
    for name, fields in [("filter_extreme",["filterBp_2800","filterLp_2900"]),("tva_saturation",["filterOutput_2a00"])]:
        assert any(v(row,field) in [0x7fffff,0x800000] for row in state(name) for field in fields), f"Boundary not exercised: {name}"
    assert [v(state("retrigger")[i],"runtimeCache.runtimePhase") for i in [64,128,129,130]] == [0,2,3,4]
    assert all(int(state("power_reset")[i]["sampleClock"]) == 1 for i in [64,128])
    assert {int(row["irqStatus"]) for row in state("irq_retry")} == {0x1234,8}
    assert any(int(row["irqBlockedEvent"]) for row in state("irq_retry"))
    assert any(int(row["irqStatus"]) == 5 and int(row["interrupt"]) for row in state("loop_irq"))
    assert any(v(row,"ampRamp_1a00") & 0x20000 for row in state("ramp_irq"))
    held = state("amp_hold_pending")
    assert all(v(row,"ampDestination_1500") & 1 == 0 for row in held[:64]) and any(v(row,"ampDestination_1500") & 1 for row in held[64:])
    for divider in range(1,4):
        assert any(v(row,"ampCurrent_1e00") < 0x18000 for row in state(f"ramp_divider_{divider}")), "Ramp divider did not service an actual update"
    for structure in range(2,11):
        pair = state(f"pair_structure_{structure}")
        assert any(v(row,"filterOutput_2a00") for row in pair)
        assert all(int(row["voice[1].filterOutput_2a00"]) == 0 for row in pair)
    sweep = [row for row in rows(golden / "phase_sweep/stages.csv") if row["stage"] == "interpolation"]
    assert {int(row["a"]) >> 7 & 127 for row in sweep} == set(range(128))
    negative = next(row for row in rows(golden / "filter_negative_truncation/stages.csv") if row["stage"] == "filter")
    assert int(negative["c"]) == 0 and int(negative["e"]) == -1, "Negative coefficient product must truncate toward zero"
    return ["launch_three_frame_order", "DPCM_wrap_phase_all_128_bins", "forward_reverse_alternate_and_address_wrap", "four_filter_modes_and_negative_truncation", "TVF_TVA_saturation_and_reset_decay", "ramps_hold_dividers_IRQ_retry_retrigger_reset", "all_pair_structures_2_to_10"]


def gate_a():
    previous = json.loads((ROOT / "build/verification/phase-01/gate-D.json").read_text(encoding="utf-8"))
    assert previous["status"] == "通过" and not previous["failed_checks"], "Phase 1 D must pass first"
    assert CONTRACT["upstream_commit"] == p0.LOCK["commit"]
    assert subprocess.check_output(["git","-C",str(p0.UPSTREAM),"rev-parse","HEAD"],text=True).strip() == p0.LOCK["commit"]
    assert not subprocess.check_output(["git","-C",str(p0.UPSTREAM),"status","--porcelain"],text=True).strip()
    source = (p0.UPSTREAM / "source/ronaldo/custom_chips/xp/xp_host.cpp").read_text(encoding="utf-8")
    widths = {name:int(width) for name,width in re.findall(r"return \{&v\.(\w+), (\d+)\};",source)}
    assert len(widths) == 33 and all(CONTRACT["state_widths"][name] == width for name,width in widths.items())
    assert CONTRACT["part"] == "xc7z010clg400-1" and CONTRACT["target_clock_ns"] == 10
    assert len(CONTRACT["cases"]) == 60 and CONTRACT["sample_rate"] == 32000
    p0.run(["pwsh","-NoProfile","-File",str(ROOT / "scripts/build_voice_reference.ps1")],OUT / "logs/build_voice_reference.log")
    golden = OUT / "golden"
    repeat = OUT / "golden-repeat"
    for directory,log in [(golden,"vectors.log"),(repeat,"vectors-repeat.log")]:
        p0.run([str(BIN / "sc88_voice_vectors.exe"),str(directory)],OUT / "logs" / log)
        assert "SC88_VOICE_VECTORS_COMPLETE cases=60" in (OUT / "logs" / log).read_text(encoding="utf-8")
    manifest = list(rows(golden / "manifest.csv"))
    assert [row["case"] for row in manifest] == CONTRACT["cases"]
    declared = {row["case"]:row for row in manifest}
    evidence = []
    for case in CONTRACT["cases"]:
        for name in ["initial.csv","expected.csv","rom-reads.csv","stages.csv","events.csv","source-before.csv","source-after.csv"]:
            assert (golden / case / name).read_bytes() == (repeat / case / name).read_bytes(), f"Non-deterministic golden: {case}/{name}"
        assert len(list(rows(golden / case / "initial.csv"))) == 1
        metrics = validate_states(golden / case / "expected.csv",CONTRACT["synthetic_frames"])
        reads = sum(1 for _ in rows(golden / case / "rom-reads.csv"))
        stages = sum(1 for _ in rows(golden / case / "stages.csv"))
        assert reads == int(declared[case]["rom_reads"]) and metrics["active_frames"] == int(declared[case]["active_frames"])
        assert metrics["frames"] == int(declared[case]["frames"])
        if metrics["active_frames"]:
            assert stages > 0, f"Missing intermediate stage observations: {case}"
        source_count = validate_source_observations(golden / case / "source-before.csv", golden / case / "source-after.csv")
        if metrics["active_frames"]:
            assert source_count > 0, f"Missing source observations: {case}"
        evidence.append({"case":case, **metrics,"rom_reads":reads,"stage_observations":stages,"source_transactions":source_count,"repeat_exact":True})
    assert (golden / "synthetic-wave.bin").read_bytes() == (repeat / "synthetic-wave.bin").read_bytes()
    assert len(list(rows(golden / "pitch-table.csv"))) == 256
    assert len(list(rows(golden / "interpolation-table.csv"))) == 384
    for name in ["pitch-table.csv","interpolation-table.csv"]:
        assert (golden / name).read_bytes() == (repeat / name).read_bytes()
    checks = semantic_checks(golden)
    trace = CONTRACT["trace_case"]
    old = ROOT / "build/verification/phase-01/cases" / trace["case"]
    destination = OUT / "trace-piano"
    p0.run([str(BIN / "sc88_voice_trace_probe.exe"),str(ROOT / "private/roms"),str(old / "export/register.trace"),str(destination),p0.LOCK["commit"],str(trace["first_voice"])],OUT / "logs/trace-piano.log")
    assert "SC88_REPLAY_COMPLETE" in (OUT / "logs/trace-piano.log").read_text(encoding="utf-8")
    pcm = {}
    for name,length in [("boot",trace["boot_frames"]),("native",trace["frames"])]:
        pcm[name] = compare(old / "reference" / f"{name}.pcm", destination / f"{name}.pcm",length)
        assert pcm[name]["success"], "Voice observation changes golden audio"
    replay = json.loads((destination / "replay.json").read_text(encoding="utf-8"))
    assert replay["success"] and replay["state_checkpoints"] == 17 and replay["cpu_instructions"] == 0 and not replay["control_rom_loaded"]
    real = validate_states(destination / "voice-expected.csv",trace["frames"],trace["boot_frames"])
    assert real["active_frames"] > 0, "Observed Voice pair did not produce audio"
    rom_reads = sum(1 for _ in rows(destination / "voice-rom-reads.csv"))
    assert rom_reads > 0, "No actual sample fetch observed"
    assert validate_source_observations(destination / "voice-source-before.csv", destination / "voice-source-after.csv") > 0
    p0.write_json(OUT / "golden-coverage.json",{"success":True,"cases":evidence,"semantic_checks":checks,"trace":{"case":"piano","first_voice":62,"active_voice":63,**real,"rom_reads":rom_reads,"state_checkpoints":17,"PCM":pcm}})
    notice = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
    assert "Phase 2" in notice and "voice" in notice
    assert not subprocess.check_output(["git","-C",str(p0.UPSTREAM),"status","--porcelain"],text=True).strip()
    return ["phase1_D_entry","pinned_pristine_sources_and_register_widths","MSVC_Voice_probe_build","60_deterministic_256_frame_golden_cases",*checks,"real_piano_Voice63_and_actual_ROM_reads","source_snapshots_before_Ramp_IRQ_arbitration","observation_exact_PCM_and_17_original_state_checkpoints","GPL_and_private_evidence_boundary"]


def validate_source_observations(before, after):
    count = 0
    previous = (-1, -1)
    for pre, post in zip(rows(before), rows(after), strict=True):
        key = (int(pre["frame"]), int(pre["voiceIndex"]))
        assert key > previous and key == (int(post["frame"]), int(post["voiceIndex"])), f"Source observation ordering differs: {before}"
        assert pre["sampleClock"] == post["sampleClock"], "Source stage advanced global clock"
        assert 0 <= int(pre["descriptor"]) <= 255 and pre["physical16"] in ("0", "1")
        assert pre["acceptedThisFrame"] in ("0", "1") and post["acceptedThisFrame"] in ("0", "1")
        previous = key
        count += 1
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase",type=int,default=2)
    parser.add_argument("--step",choices=list("ABCD"),default="A")
    parser.add_argument("--rom-path",default="")
    args = parser.parse_args()
    if args.phase != 2:
        parser.error("Only Phase 2 is handled here")
    if args.rom_path:
        parser.error("Gate A uses Phase 0's validated private/roms; import a different ROM source through Phase 0 before running this gate")
    summary = {"schema_version":1,"phase":2,"status":"进行中","scope":"software_contract","commit":p0.LOCK["commit"],"gate_status":{step:"未开始" for step in "ABCD"},"hardware_verified":False,"hardware_status":"NOT_TESTED_ON_HARDWARE","hls_csim":"UNVERIFIED","hls_synthesis":"UNVERIFIED","hls_cosim":"UNVERIFIED","hls_resources":"UNVERIFIED","hls_timing":"UNVERIFIED","limit":"Gate A fixes executable goldens and interfaces; no HLS numerical core or Phase 2 completion claim"}
    for destination in [OUT / "summary.json", ROOT / "verification/phase-02/summary.json"]:
        p0.write_json(destination,summary)
    for step in "ABCD":
        p0.write_json(OUT / f"gate-{step}.json",{"schema_version":1,"phase":2,"step":step,"status":"未开始","scope":"software_contract","checks":[],"failed_checks":[],"hardware_verified":False})
    checks = []
    try:
        for step in "ABCD"[:"ABCD".index(args.step)+1]:
            summary["gate_status"][step] = "进行中"
            p0.write_json(OUT / f"gate-{step}.json",{"schema_version":1,"phase":2,"step":step,"status":"进行中","scope":"software_contract","checks":checks,"failed_checks":[],"hardware_verified":False})
            if step != "A":
                raise RuntimeError(f"Phase 2 Gate {step} is not implemented; HLS core, C simulation, synthesis and C/RTL co-simulation remain required")
            checks.extend(gate_a())
            summary["gate_status"][step] = "通过"
            p0.write_json(OUT / f"gate-{step}.json",{"schema_version":1,"phase":2,"step":step,"status":"通过","scope":"software_contract","checks":checks,"failed_checks":[],"hardware_verified":False})
            summary.update({"golden_cases":60,"golden_frames":15360,"trace_frames":256000,"state_checkpoints":17,"observation_max_absolute_error":0})
            coverage = json.loads((OUT / "golden-coverage.json").read_text(encoding="utf-8"))
            summary.update({"trace_rom_reads":coverage["trace"]["rom_reads"],"golden_state_columns":coverage["cases"][0]["columns"]})
            print(f"Phase 2 Gate {step}: passed ({len(checks)} checks)",flush=True)
    except Exception as error:
        summary["status"] = "未通过"
        summary["gate_status"][step] = "未通过"
        p0.write_json(OUT / f"gate-{step}.json",{"schema_version":1,"phase":2,"step":step,"status":"未通过","scope":"software_contract","checks":checks,"failed_checks":[str(error)],"hardware_verified":False})
        raise
    finally:
        p0.write_json(OUT / "summary.json",summary)
        p0.write_json(ROOT / "verification/phase-02/summary.json",summary)


if __name__ == "__main__":
    main()
