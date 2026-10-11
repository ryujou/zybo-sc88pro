"""Exercise cold parameter schedules and fault recovery on the paired Zybo board."""
import os
import argparse
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

from offline_parameter_dma import decode, encode

ROOT = Path(__file__).resolve().parents[1]
PHASE = ROOT / "build/verification/offline-player/phase-04"
OUT = PHASE / "hardware/current-board-probe"
XSCT = str(Path(os.environ["VITIS_ROOT"]) / "bin/xsct.bat")


def prepare(voices, frames, mode="normal"):
    assert voices in (1, 32, 64) and frames in (1, 32)
    destination = OUT / f"{mode}-{voices}-{frames}"
    destination.mkdir(parents=True, exist_ok=True)
    parameters, commands = bytearray(32 * 16384), bytearray(8192)
    for frame in range(frames):
        packet = encode(frame, [], [])
        assert decode(packet, frame) == (frame, [], [])
        parameters[frame * 16384:frame * 16384 + 32] = packet
        slot, index = divmod(frame, 16)
        last = mode != "late" and frame == frames - 1
        struct.pack_into("<8Q", commands, slot * 4096 + index * 64,
                         0x53434431 | (int(last) << 33), frame,
                         (32 << 32) | (0x12000000 + frame * 16384),
                         0, 0x1f00 | (voices - 1), 0, 0, 0)
    if mode == "header":
        parameters[0] ^= 1
    elif mode == "truncated":
        struct.pack_into("<I", parameters, 16, 64)
    (destination / "parameters.bin").write_bytes(parameters)
    (destination / "commands.bin").write_bytes(commands)
    return destination


def descriptor(offset, address, size, result, result_bytes, frames, first, last):
    values = [address, size, result, result_bytes, frames, first, 0, 0x101 if last else 1]
    return "\n".join(f"wr 0x{offset + index * 4:x} 0x{value:x}" for index, value in enumerate(values))


def connect(serial):
    return f'''connect -url tcp:127.0.0.1:3121
targets -set -filter {{name == "ARM Cortex-A9 MPCore #0" && jtag_cable_serial == "{serial}"}}
stop
configparams force-mem-access 1
proc rd {{offset}} {{return [lindex [mrd -value [expr {{0x43c00000 + $offset}}]] 0]}}
proc wr {{offset value}} {{mwr [expr {{0x43c00000 + $offset}}] $value}}
proc require {{expression message}} {{if {{![uplevel 1 [list expr $expression]]}} {{error $message}}}}
proc until {{expression}} {{
    set start [clock milliseconds]
    while {{![uplevel 1 [list expr $expression]]}} {{
        if {{[clock milliseconds] - $start > 3000}} {{error "Timed out: $expression; fault=[rd 0xc]"}}
        after 1
    }}
}}
'''


RESET = '''wr 4 4
until {[rd 8] == 1 && [rd 0x84] == 7 && [rd 0x80] == 0 && [rd 0x88] == 0}
require {[rd 0xc] == 0 && [rd 0x18] == 0 && [rd 0x3c] == 0} "Reset did not clear fault/counters/FIFO"
'''

FAULT_WRITES = '''set saved [rd 0x100]
set owners [rd 0x80]
set fault [rd 0xc]
wr 0x100 0xaaaaaaaa
wr 0x11c 1
wr 4 17
require {[rd 0x100] == $saved && [rd 0x80] == $owners && [rd 0xc] == $fault} "Fault-time writes changed state"
wr 4 8
until {[rd 0x84] == 7}
'''


def run_tcl(destination, name, body, serial):
    path = destination / f"{name}.tcl"
    path.write_text(connect(serial) + body + '\ncon\nputs "SC88_BOARD_PROBE_STEP_COMPLETE"\ndisconnect\n', encoding="utf-8")
    result = subprocess.run([XSCT, str(path)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    (destination / f"{name}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    result.check_returncode()
    assert re.search(r"(?m)^SC88_BOARD_PROBE_STEP_COMPLETE\r?$", result.stdout), result.stdout + result.stderr
    return result.stdout


def cold_case(voices, frames, mode, serial):
    destination = prepare(voices, frames, mode)
    words = voices * 4 + 64
    body = RESET + f'''dow -data {{{(destination / 'parameters.bin').as_posix()}}} 0x12000000
dow -data {{{(destination / 'commands.bin').as_posix()}}} 0x05000000
'''
    blocks = (frames + 15) // 16
    for slot in range(blocks):
        count = min(16, frames - slot * 16)
        body += descriptor(0x100 + slot * 32, 0x05000000 + slot * 4096, count * 64,
                           0x06000000 + slot * 65536, count * words * 8, count, slot * 16,
                           mode != "late" and slot == blocks - 1) + "\n"
    body += "wr 4 1\n"
    if mode in ("header", "truncated"):
        body += 'until {[rd 0xc] != 0}\nrequire {([rd 0xc] & 8) != 0 && [rd 0x18] == 0} "Malformed header was not rejected before frame completion"\n'
        run_tcl(destination, "header-fault", body + FAULT_WRITES + RESET, serial)
        return dict(voices=voices, frames=frames, mode=mode, parameter_fault_observed=True, fault_writes_ignored=True, reset_ready=True)
    body += f'until {{[rd 0x24] == {frames} || [rd 0xc] != 0}}\nrequire {{[rd 0xc] == 0 && [rd 0x18] == {frames}}} "Cold synthesis failed"\n'
    for slot in range(blocks):
        count = min(16, frames - slot * 16)
        body += f'until {{(([rd 0x80] >> {slot * 2}) & 3) == 3}}\n'
        body += f'mrd -bin -file {{{(destination / f"results-{slot}.bin").as_posix()}}} 0x{0x06000000 + slot * 65536:x} {count * words * 2}\n'
    run_tcl(destination, "synthesis", body, serial)
    audio = bytearray(8192)
    for slot in range(blocks):
        count = min(16, frames - slot * 16)
        raw = (destination / f"results-{slot}.bin").read_bytes()
        assert len(raw) == count * words * 8
        for frame in range(count):
            row = struct.unpack_from(f"<{words}Q", raw, frame * words * 8)
            for index, word in enumerate(row):
                assert word & 0x1ffffff == 0, (slot, frame, index, "Cold contribution differs")
                assert word >> 63 == int(index >= voices * 4), "Result type differs"
                if index < voices * 4:
                    assert (word >> 48) & 63 == index // 4 and (word >> 46) & 3 == index % 4, "Send order differs"
                else:
                    assert (word >> 40) & 63 == index - voices * 4, "Mixer order differs"
            # Return the actual PL mixer samples, never a golden PCM input.
            left, right = (row[voices * 4 + cell] & 0xffffff for cell in (8, 9))
            left = left - (1 << 24) if left & (1 << 23) else left
            right = right - (1 << 24) if right & (1 << 23) else right
            struct.pack_into("<ii", audio, slot * 4096 + frame * 8, left, right)
    (destination / "returned-audio.bin").write_bytes(audio)
    body = f'dow -data {{{(destination / "returned-audio.bin").as_posix()}}} 0x07000000\n'
    for slot in range(blocks):
        count = min(16, frames - slot * 16)
        body += f"wr 0x{0x11c + slot * 32:x} 2\n"
        body += descriptor(0x180 + slot * 32, 0x07000000 + slot * 4096, count * 8,
                           0, 0, count, slot * 16, mode != "late" and slot == blocks - 1) + "\n"
    body += f'until {{[rd 0x3c] == {frames} || [rd 0xc] != 0}}\nrequire {{[rd 0xc] == 0}} "Audio DMA failed"\nwr 4 16\n'
    if mode == "late":
        body += f'until {{[rd 0xc] != 0}}\nrequire {{([rd 0xc] & 0xf00) == 0x300 && [rd 0x18] == {frames}}} "Missing next command did not latch deadline fault"\n'
        body += FAULT_WRITES
    else:
        body += f'until {{([rd 8] & 16) != 0 || [rd 0xc] != 0}}\nrequire {{[rd 0xc] == 0 && [rd 0x3c] == 0 && [rd 0x90] == {frames}}} "Final I2S/FIFO drain failed"\n'
    body += 'puts "SC88_COLD_COUNTERS completed=[rd 0x18] returned=[rd 0x90] max_frame=[rd 0x20]"\n' + RESET
    output = run_tcl(destination, "return-and-drain", body, serial)
    timing = re.search(r"max_frame=(0x[0-9a-fA-F]+|[0-9]+)", output)
    assert timing and int(timing[1], 0) <= 3125
    return dict(voices=voices, frames=frames, mode=mode, samples_exact=True, result_records=frames * words,
                max_frame_cycles=int(timing[1], 0), reset_ready=True, deadline_fault_observed=mode == "late")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cable-serial", required=True)
    args = parser.parse_args()
    assert re.fullmatch(r"[A-Za-z0-9]+", args.cable_serial)
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(scope="parameter_board_cold_schedules_and_fault_recovery", success=False, hardware_verified=False,
                  phase4_gate_passed=False, cases=[], limitation="Cold unreleased Voices only; active MIDI, PS/USB, signed I2S and full effects require separate evidence.")
    try:
        result = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "host/parameter_jtag.py"),
                                 "--load", "--cable-serial", args.cable_serial], cwd=ROOT,
                                capture_output=True, text=True, encoding="utf-8", errors="replace")
        (OUT / "jtag-load.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        result.check_returncode()
        assert "SC88_PARAMETER_JTAG_STARTED" in result.stdout
        for voices in (1, 32, 64):
            for frames in (1, 32):
                report["cases"].append(cold_case(voices, frames, "normal", args.cable_serial))
        report["cases"].append(cold_case(64, 1, "header", args.cable_serial))
        report["cases"].append(cold_case(64, 1, "truncated", args.cable_serial))
        report["cases"].append(cold_case(64, 32, "late", args.cable_serial))
        report["cases"].append(cold_case(64, 1, "recovery", args.cable_serial))
        report.update(success=True, hardware_verified=True)
        print(json.dumps(report))
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
