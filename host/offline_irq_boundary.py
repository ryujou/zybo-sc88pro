"""Run original/control-export/parameter-consumer shared-IRQ boundary fixtures."""
import json
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-01"
BIN = ROOT / "build/offline-player/Release"
CASES = ["mute_before_loop_terminal", "loop_before_terminal_coalesced", "pending_IRQ_blocks_other_voice", "masked_loop_terminal_accepts", "all_masked_unarmed",
         "owner_mute_blocks_partner_terminal", "paired_source_order", "reverse_alternate_loop", "initialize_pre_post_control", "starting_TVF_control", "parked_source", "preload_markers",
         "post_source_pitch_refresh", "incoming_combinedAmp_TVA", "pitch_terminal", "TVF_Q_terminal", "TVF_F_terminal", "amp_mod_terminal", "held_pending_destination", "masked_mute_terminal_accepts", "amp_curve2_boundary", "amp_curve3_zero_boundary"]


def run():
    results = []
    for index, name in enumerate(CASES):
        case = OUT / "irq-boundary" / name
        for mode in range(3):
            result = subprocess.run([str(BIN / f"sc88_offline_irq_{mode}.exe"), str(index), str(case)], capture_output=True, text=True, encoding="utf-8")
            case.mkdir(parents=True, exist_ok=True)
            (case / f"mode-{mode}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
            if result.returncode or "SC88_OFFLINE_IRQ_PROBE_COMPLETE" not in result.stdout:
                raise RuntimeError(f"IRQ fixture {name}, mode {mode}: {result.stdout}{result.stderr}")
        reference = (case / "reference.state").read_bytes()
        if len(reference) != 64 * 202 * 8:
            raise ValueError("IRQ fixture omitted a frame/state field")
        for actual in ["export", "replay"]:
            data = (case / f"{actual}.state").read_bytes()
            if data != reference:
                for offset, (expected, observed) in enumerate(zip(struct.iter_unpack("<Q", reference), struct.iter_unpack("<Q", data))):
                    if expected != observed:
                        raise ValueError(f"IRQ first difference {name}/{actual}: frame={offset//202} field_index={offset%202} reference={expected[0]} actual={observed[0]}")
                raise ValueError(f"IRQ state length difference {name}/{actual}")
        first = struct.unpack_from("<202Q", reference)
        if index in [0, 1, 3, 14, 15, 16, 17, 19]:
            reason = {0: 8, 1: 5, 3: 4, 14: 2, 15: 0, 16: 1, 17: 3, 19: 4}[index]
            if not first[1] or first[2] != reason:
                raise ValueError(f"IRQ fixture did not exercise expected first owner/reason: {name}, {first[:6]}")
        if index == 2 and (not first[3] or first[2] != 0x105):
            raise ValueError("Pending IRQ fixture did not block the competing voice")
        if index == 4 and first[1]:
            raise ValueError("Masked/unarmed fixture unexpectedly accepted IRQ")
        if index == 1 and first[33] & 0x30000 != 0x30000:
            raise ValueError("Loop markers did not coalesce into both readable stages")
        if index == 3 and not first[6+22+4] & 0x20000:
            raise ValueError("Accepted amp terminal did not set local hold")
        results.append({"case": name, "frames": 64, "words_per_frame": 202, "export_exact": True, "replay_exact": True, "first_IRQ_status": first[2], "first_blocked": bool(first[3])})
    report = {"success": True, "scope": "offline_parameter_player_software", "original_reference": "unmodified pinned xpLib", "cases": results,
              "frames": len(CASES) * 64, "golden_post_state_input": False, "initial_state": "same authored synthetic fixture in all three executables; no later state restoration", "hardware_verified": False}
    (OUT / "irq-boundary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    print(json.dumps(run(), ensure_ascii=False))
