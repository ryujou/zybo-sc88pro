"""Export a real TH06 MIDI window for independent 64 Voice board RTL playback."""
import argparse
import json
import subprocess
import sys
from phase4 import ROOT,OUT
from prepare_voice_probe import main as voice_overlay
from prepare_board_probe import main as board_overlay
from prepare_board_trace import make_trace


def main():
    parser=argparse.ArgumentParser()
    selection=parser.add_mutually_exclusive_group()
    selection.add_argument("--song",choices=[f"th06_{i:02}" for i in range(1,8)],default="th06_01")
    selection.add_argument("--piano",action="store_true",help="existing real-ROM piano regression, not Touhou acceptance")
    parser.add_argument("--first-frame",type=int)
    parser.add_argument("--frames",type=int,default=4096)
    args=parser.parse_args()
    if args.first_frame is None:args.first_frame=260000 if args.piano else 352000
    out=OUT/"piano" if args.piano else OUT/"touhou"/args.song
    out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False,song=args.song,first_frame=args.first_frame,frames=args.frames,
                 scope="real_MIDI_diagnostic_window",input_unmodified=True,full_song_verified=False,
                 left_cell=8,right_cell=9)
    if args.piano:summary.update(song="piano",scope="real_ROM_piano_diagnostic_window",input_unmodified=True)
    def execute(command,name):
        with (out/name).open("w",encoding="utf-8") as log:
            subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    try:
        lock=json.loads((ROOT/"reference/gearmulator-lock.json").read_text(encoding="utf-8"))
        upstream=ROOT/"external/gearmulator"
        assert subprocess.check_output(["git","-C",str(upstream),"rev-parse","HEAD"],text=True).strip()==lock["commit"]
        assert not subprocess.check_output(["git","-C",str(upstream),"status","--porcelain"],text=True).strip()
        if args.piano:
            baseline=ROOT/"build/verification/phase-01/cases/piano"
            result=json.loads((ROOT/"reference/phase1-contract.json").read_text(encoding="utf-8"))
            result.update(status=json.loads((ROOT/"verification/phase-01/summary.json").read_text(encoding="utf-8"))["status"],title="Piano ROM regression")
        else:
            baseline=ROOT/"build/verification/th06-midi"/args.song
            result=json.loads((baseline/"result.json").read_text(encoding="utf-8"))
        assert result["status"]=="通过" and args.first_frame>=result["boot_frames"] and 0<args.frames<=32768
        assert args.first_frame+args.frames<=result["boot_frames"]+result["case_frames"]
        if not args.piano:
            midi=ROOT/"private/midi/th06-demo/midi"/(args.song+".mid")
            assert midi.read_bytes()[:4]==b"MThd"
        voice_overlay();board_overlay()
        execute(["cmake","-S","host/voice_reference","-B","build/board-reference","-G","Visual Studio 17 2022","-A","x64","-DSC88_BOARD_PROBE=ON"],"configure.log")
        execute(["cmake","--build","build/board-reference","--config","Release","--target","sc88_board_trace_probe","--parallel","8"],"build.log")
        execute([str(ROOT/"build/board-reference/Release/sc88_board_trace_probe.exe"),str(ROOT/"private/roms"),
                 str(baseline/"export/register.trace"),str(out),lock["commit"],str(args.first_frame),str(args.frames)],"capture.log")
        with (baseline/"reference/native.pcm").open("rb") as reference:
            reference.seek((args.first_frame-result["boot_frames"])*8)
            expected=reference.read(args.frames*8)
        observed=(out/"reference.pcm").read_bytes()
        assert len(expected)==args.frames*8 and observed==expected,"MIDI capture reference PCM differs from the original whole-song baseline"
        packet,trace=make_trace(out,args.frames,left=8,right=9)
        (out/"commands.bin").write_bytes(packet)
        summary.update(success=True,title=result["title"],
                       trace=str((baseline/"export/register.trace").relative_to(ROOT)),
                       diagnostic_seconds=args.frames/32000,reference_pcm_exact=True,commands=trace)
        if not args.piano:summary["midi"]=str(midi.relative_to(ROOT))
        print(json.dumps(summary,ensure_ascii=False))
    finally:(out/"input.json").write_text(json.dumps(summary,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")


if __name__=="__main__":main()
