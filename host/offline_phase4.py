"""Parameter-board gates; software contracts never substitute for board execution."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/verification/offline-player/phase-04"
PUBLIC=ROOT/"verification/offline-player/phase-04"


def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")


def execute(script,step,extra=()):
    print("Phase4 "+step+": "+script,flush=True)
    result=subprocess.run([sys.executable,"-X","utf8",str(ROOT/"host"/script),*extra],cwd=ROOT,capture_output=True,text=True,encoding="utf-8",errors="replace")
    (OUT/"logs").mkdir(parents=True,exist_ok=True)
    (OUT/"logs"/(script+".log")).write_text(result.stdout+result.stderr,encoding="utf-8")
    result.check_returncode()


def gate_a(checks):
    prior=json.loads((ROOT/"verification/offline-player/phase-03/summary.json").read_text(encoding="utf-8"))
    assert prior["scope"]=="offline_parameter_multivoice_ddr_mixer_rtl" and all(prior["gate_status"][s]=="通过" for s in "ABCD")
    checks.append("current_parameter_Phase3_D")
    preset=(ROOT/"hardware/board/zybo_ps7.tcl").read_text(encoding="utf-8")
    for n,value in enumerate(["-0.073","-0.034","-0.03","-0.082"]):
        assert re.search(r"CONFIG\.PCW_UIPARAM_DDR_DQS_TO_CLK_DELAY_"+str(n)+r"\s+\{"+re.escape(value)+r"\}",preset)
    assert "PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF}" in preset
    checks.append("original_Zybo_B3_published_DDR_delays_512MiB")
    cases=[("build_storage_probe.py","storage-platform"),("test_storage_disk.py","storage-disk"),
           ("test_usb_ehci.py","usb-ehci"),
           ("test_host_config.py","host-config"),("test_parameter_frame.py","parameter-frame"),
           ("test_parameter_reader.py","parameter-reader"),("test_parameter_files.py","parameter-files"),
           ("test_frame_prepare.py","frame-prepare"),("test_parameter_audio_contract.py","audio-contract")]
    for script,folder in cases:
        execute(script,"A")
        evidence=json.loads((OUT/folder/"summary.json").read_text(encoding="utf-8"))
        assert evidence["success"] and evidence["hardware_verified"] is False
        if "songs" in evidence: assert len(evidence["songs"])==7
        checks.append(folder)
    for n in range(1,8): assert (ROOT/"private/midi/th06-demo/midi"/f"th06_{n:02d}.mid").is_file()
    checks.append("seven_original_Touhou_MIDI_inputs")


def gate_b(checks,finalize_board=False):
    cases=[("test_parameter_blocks.py","parameter-blocks"),
           ("test_parameter_commands.py","parameter-commands"),
           ("test_parameter_results.py","parameter-results"),
           ("test_parameter_block_queue.py","parameter-block-queue"),
           ("test_return_audio.py","return-audio"),
           ("test_parameter_audio_bridge.py","parameter-audio-bridge"),
           ("test_parameter_synth.py","parameter-synth"),
           ("test_parameter_registers.py","parameter-registers"),
           ("test_parameter_board.py","parameter-board-control"),
           ("test_parameter_playback.py","parameter-playback"),
           ("test_parameter_audio.py","parameter-audio"),
           ("test_parameter_service.py","parameter-service"),
           ("build_parameter_board.py","board"),
           ("build_parameter_ps.py","parameter-ps")]
    for script,folder in cases:
        execute(script,"B",["--finalize"] if finalize_board and folder=="board" else [])
        evidence=json.loads((OUT/folder/"summary.json").read_text(encoding="utf-8"))
        assert evidence["success"] and evidence["hardware_verified"] is False
        if "songs" in evidence: assert len(evidence["songs"])==7
        if folder=="parameter-ps":
            assert evidence["xsa_contains_bit"] and Path(evidence["xsa"]).resolve()==(OUT/"board/sc88.xsa").resolve()
        checks.append(folder)
    # These shared blocks retain the legacy mode as well as the parameter path.
    for script,folder in [("test_block_dma.py","block-dma"),("test_block_queue.py","block-queue"),("test_audio_bridge.py","audio-bridge")]:
        execute(script,"B")
        evidence=json.loads((ROOT/"build/verification/phase-04"/folder/"summary.json").read_text(encoding="utf-8"))
        assert evidence["success"] and evidence["hardware_verified"] is False
        checks.append("shared_"+folder)
    execute("parameter_jtag.py","B")
    checks.append("paired_bit_XSA_ELF_JTAG_offline_check")


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--phase",type=int,default=4,choices=[4])
    parser.add_argument("--step",choices=list("ABCD"),default="A")
    parser.add_argument("--rom-path",default="")
    parser.add_argument("--offline",action="store_true")
    parser.add_argument("--finalize-board",action="store_true",help="Reuse unchanged routed RTL/platform and recheck/export its board artifacts")
    args=parser.parse_args()
    summary=dict(schema_version=1,phase=4,scope="offline_parameter_board",status="进行中",
                 gate_status={s:"未开始" for s in "ABCD"},hardware_verified=False,hardware_status="NOT_TESTED_ON_HARDWARE")
    checks=[]
    for step in "ABCD"[:"ABCD".index(args.step)+1]:
        gate=dict(schema_version=1,phase=4,step=step,scope=summary["scope"],status="进行中",checks=checks,failed_checks=[],hardware_verified=False)
        save(OUT/("gate-"+step+".json"),gate)
        try:
            if step=="A": gate_a(checks)
            elif step=="B": gate_b(checks,args.finalize_board)
            else: raise RuntimeError("Phase 4 "+step+" integration/hardware requirements are not implemented or verified")
            gate["status"]=summary["gate_status"][step]="通过"
        except Exception as error:
            gate["status"]=summary["gate_status"][step]="未通过"
            gate["failed_checks"]=[str(error)]
            summary["status"]="未通过"
            raise
        finally:
            save(OUT/("gate-"+step+".json"),gate)
            save(OUT/"summary.json",summary)
            save(PUBLIC/"summary.json",summary)
    print(json.dumps(summary,ensure_ascii=False),flush=True)


if __name__=="__main__":main()
