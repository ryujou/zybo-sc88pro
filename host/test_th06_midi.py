"""Full-song official TH06 demo MIDI -> original reference -> CPU-free Trace replay."""
import argparse
from collections import Counter
from fractions import Fraction
import json
import math
from pathlib import Path
import re
import struct
import wave

import phase0 as p0
from sc88_audio_compare import compare

ROOT = p0.ROOT
OUT = ROOT / "build/verification/th06-midi"
INPUT = ROOT / "private/midi/th06-demo/midi"
BOOT_FRAMES = 256000
TAIL_FRAMES = 256000
SOURCE_PAGE = "https://www16.big.or.jp/~zun/html/th06.html"
SOURCE_ARCHIVE = "https://www16.big.or.jp/~zun/data/soft/kouma_tr013.lzh"


def midi_stats(path):
    """Inspect PPQN SMF timing/counts; playback uses upstream readSmf, not this parser."""
    data = path.read_bytes()
    if data[:4] != b"MThd":
        raise ValueError("Missing MThd")
    header_size, fmt, track_count, division = struct.unpack_from(">IHHH",data,4)
    if fmt not in [0,1] or not division or division & 0x8000:
        raise ValueError("This song test expects format 0/1 PPQN SMF")
    position = 8 + header_size
    raw = []
    end_tick = 0
    counts = Counter()
    channels = set()
    ports = set()
    markers = []
    for track in range(track_count):
        if data[position:position + 4] != b"MTrk":
            raise ValueError("Missing MTrk")
        size = struct.unpack_from(">I",data,position + 4)[0]
        position += 8
        end = position + size
        tick, running, port = 0, 0, 0
        def vlq():
            nonlocal position
            value = 0
            for _ in range(4):
                byte = data[position]
                position += 1
                value = value * 128 + (byte & 127)
                if not byte & 128:
                    return value
            raise ValueError("Invalid VLQ")
        while position < end:
            tick += vlq()
            status = data[position]
            if status & 128:
                position += 1
            else:
                if not running:
                    raise ValueError("Missing running status")
                status = running
            if status == 255:
                kind = data[position]
                position += 1
                length = vlq()
                payload = data[position:position + length]
                position += length
                if kind == 81:
                    raw.append((tick,len(raw),int.from_bytes(payload,"big"),False))
                    counts["tempo"] += 1
                elif kind == 33:
                    port = payload[0]
                    ports.add(port)
                elif kind in [6,7]:
                    # Marker bytes may express game loop cues; do not reinterpret or erase them.
                    markers.append({"tick":tick,"type":kind,"bytes_hex":payload.hex()})
                elif kind == 47:
                    break
            elif status in [240,247]:
                length = vlq()
                payload = data[position:position + length]
                position += length
                running = 0
                raw.append((tick,len(raw),0,True))
                counts["sysex"] += 1
                ports.add(port)
            elif 128 <= status < 240:
                running = status
                length = 1 if status & 240 in [192,208] else 2
                payload = data[position:position + length]
                position += length
                category = {128:"note_off",144:"note_on",160:"poly_pressure",176:"control_change",192:"program_change",208:"channel_pressure",224:"pitch_bend"}[status & 240]
                if category == "note_on" and payload[1] == 0:
                    category = "note_off"
                counts[category] += 1
                if category == "control_change":
                    counts[f"CC{payload[0]}"] += 1
                channels.add(status & 15)
                ports.add(port)
                raw.append((tick,len(raw),0,True))
            else:
                raise ValueError(f"Unsupported SMF status {status:#x}")
            if position > end:
                raise ValueError("Truncated SMF event")
        end_tick = max(end_tick,tick)
        position = end
    if position != len(data):
        raise ValueError("Unexpected SMF trailing data")
    tempo, previous = 500000, 0
    seconds = Fraction(0)
    last_event_seconds = Fraction(0)
    for tick, order, change, playable in sorted(raw):
        seconds += Fraction((tick - previous)*tempo,division*1000000)
        previous = tick
        if change:
            tempo = change
        if playable:
            last_event_seconds = seconds
    seconds += Fraction((end_tick - previous)*tempo,division*1000000)
    playable_count = sum(event[3] for event in raw)
    return {"file":path.name,"bytes":len(data),"format":fmt,"tracks":track_count,"division":division,"end_tick":end_tick,"duration_seconds":float(seconds),"last_event_seconds":float(last_event_seconds),"case_frames":math.ceil(seconds*32000)+TAIL_FRAMES,"playable_events":playable_count,"counts":dict(counts),"channels":sorted(channels),"ports":sorted(ports),"markers":markers}


def write_wav(pcm, destination, frames):
    raw, values = p0.pcm_values(pcm,frames)
    packed = bytearray(len(values)*3)
    packed[0::3],packed[1::3],packed[2::3] = raw[0::4],raw[1::4],raw[2::4]
    with wave.open(str(destination),"wb") as output:
        output.setparams((2,3,32000,0,"NONE","not compressed"))
        output.writeframes(packed)
    with wave.open(str(destination),"rb") as output:
        assert output.getnframes() == frames and output.readframes(frames) == packed
    return {"peak":max(map(abs,values)),"dynamic_samples":sum(value != 32 for value in values),"tail_frames":TAIL_FRAMES}


def song_test(path,title):
    stats = midi_stats(path)
    case = OUT / path.stem
    frames = stats["case_frames"]
    print(f"Testing {path.name} {title}: {stats['duration_seconds']:.3f}s + 8s tail, {stats['playable_events']} MIDI events",flush=True)
    metadata = {"source_page":SOURCE_PAGE,"source_archive":SOURCE_ARCHIVE,"archive_entry":"紅魔郷MD.DAT/"+path.name,"version":"official trial v0.13","title":title,"upstream_commit":p0.LOCK["commit"],"factory_reset":True,"boot_frames":BOOT_FRAMES,"sample_rate":32000,"gain":1,"resampling":False,"limiter":False,"input_unmodified":True,"midi":stats}
    p0.write_json(case / "input.json",metadata)
    duration = [str(BOOT_FRAMES),str(frames),p0.LOCK["commit"]]
    for mode, executable in [("reference",ROOT / "build/reference/Release/sc88_reference_runner.exe"),("export",ROOT / "build/trace/Release/sc88_register_trace.exe")]:
        p0.run([str(executable),str(ROOT / "private/roms"),str(path),str(case / mode),*duration],OUT / "logs" / f"{path.stem}-{mode}.log")
        runner = json.loads((case / mode / "runner.json").read_text())
        assert runner["midi_backlog"] == 0 and runner["events"] == stats["playable_events"], "SMF event count/drain mismatch"
        assert "SC88_REFERENCE_COMPLETE" in (OUT / "logs" / f"{path.stem}-{mode}.log").read_text()
        print(f"  {path.stem}: {mode} complete",flush=True)
    p0.run([str(ROOT / "build/trace/Release/sc88_trace_replay.exe"),str(ROOT / "private/roms"),str(case / "export/register.trace"),str(case / "replay"),p0.LOCK["commit"]],OUT / "logs" / f"{path.stem}-replay.log")
    replay = json.loads((case / "replay/replay.json").read_text())
    assert replay["success"] and replay["cpu_instructions"] == 0 and replay["control_rom_loaded"] is False
    assert replay["frames"] == BOOT_FRAMES + frames
    assert replay["state_checkpoints"] == 2+(BOOT_FRAMES+frames)//32768
    assert "SC88_REPLAY_COMPLETE" in (OUT / "logs" / f"{path.stem}-replay.log").read_text()
    comparisons = {}
    for mode in ["export","replay"]:
        for name, length, offset in [("boot",BOOT_FRAMES,0),("native",frames,BOOT_FRAMES)]:
            result = compare(case / "reference" / f"{name}.pcm",case / mode / f"{name}.pcm",length,case / "export/register.trace",offset)
            p0.write_json(case / f"compare-{mode}-{name}.json",result)
            assert result["success"], str(result["first_difference"])
            comparisons[f"{mode}_{name}"] = result
    assert (case / "reference/xp-end-state.csv").read_bytes() == (case / "export/xp-end-state.csv").read_bytes()
    audio = write_wav(case / "replay/native.pcm",case / "replay/native.wav",frames)
    assert audio["dynamic_samples"] > 0, "Silent game MIDI output"
    result = {"file":path.name,"title":title,"song_seconds":stats["duration_seconds"],"rendered_seconds":frames/32000,"midi_events":stats["playable_events"],"channels":stats["channels"],"midi_counts":stats["counts"],"case_frames":frames,"boot_frames":BOOT_FRAMES,"max_absolute_error":0,"rms_error":0,"first_difference":None,"state_checkpoints":replay["state_checkpoints"],"lsp_return_frames":replay["lsp_return_frames"],"audio":audio,"cpu_instructions":0,"status":"通过"}
    p0.write_json(case / "result.json",result)
    print(f"  {path.stem}: PASS exact boot/native PCM, {replay['state_checkpoints']} state checkpoints",flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inspect-only",action="store_true")
    args = parser.parse_args()
    inputs = sorted(INPUT.glob("th06_*.mid"))
    assert len(inputs) == 7, "Expected seven original demo MIDIs"
    comments = (INPUT / "musiccmt.txt").read_bytes().decode("cp932")
    titles = {name:title.strip() for name,title in re.findall(r"@bgm/(th06_\d+\.mid)\s+([^\r\n]+)",comments)}
    assert all(path.name in titles for path in inputs)
    if args.inspect_only:
        for path in inputs:
            print(json.dumps({"title":titles[path.name],**midi_stats(path)},ensure_ascii=False))
        return
    assert json.loads((ROOT / "build/verification/phase-01/gate-D.json").read_text())["status"] == "通过"
    summary = {"schema_version":1,"suite":"th06_original_demo_midi","status":"进行中","scope":"software","source_page":SOURCE_PAGE,"source_archive":SOURCE_ARCHIVE,"version":"official trial v0.13","input_unmodified":True,"upstream_commit":p0.LOCK["commit"],"hardware_verified":False,"hardware_status":"NOT_TESTED_ON_HARDWARE","songs":[]}
    p0.write_json(OUT / "summary.json",summary)
    p0.write_json(ROOT / "verification/th06-midi/summary.json",summary)
    try:
        for path in inputs:
            summary["songs"].append(song_test(path,titles[path.name]))
            p0.write_json(OUT / "summary.json",summary)
        summary.update({"status":"通过","song_count":len(inputs),"native_frames_compared":sum(song["case_frames"] for song in summary["songs"]),"boot_frames_compared":BOOT_FRAMES*len(inputs),"state_checkpoints":sum(song["state_checkpoints"] for song in summary["songs"]),"max_absolute_error":0,"rms_error":0,"limit":"original official trial tracks, one complete SMF timeline plus 8-second tail; game loop-marker restart behaviour not replayed; software only, not Phase 5 or board acceptance"})
    except Exception as error:
        # Detailed differences can contain private DSP words; keep them in case reports/logs.
        summary.update({"status":"未通过","failed_song":path.name,"error_type":type(error).__name__,"error_report":"See private build/verification/th06-midi case reports and logs"})
        raise
    finally:
        p0.write_json(OUT / "summary.json",summary)
        p0.write_json(ROOT / "verification/th06-midi/summary.json",summary)
    print(f"TH06_GAME_MIDI_COMPLETE songs=7 native_frames={summary['native_frames_compared']} max_error=0 state_checkpoints={summary['state_checkpoints']}",flush=True)


if __name__ == "__main__":
    main()
