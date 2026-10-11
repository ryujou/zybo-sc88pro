"""Implement the current admitted Voice level with cache, AXI and complete-frame output."""
import argparse
import json

from offline_phase3 import ROOT,OUT as PHASE
from test_filter_tva import run
from test_voice_units_implementation import inspect_reports


def inspect(out):
    core=inspect_reports(["pcm_parameter_voice_scheduler"],out)["pcm_parameter_voice_scheduler"]
    assert core["LUT"]<=16000 and core["FF"]<=30000 and core["DSP"]<=64 and core["BRAM18"]+2*core["BRAM36"]<=100
    return core


def main():
    parser=argparse.ArgumentParser();parser.add_argument("--voices",type=int,choices=[1,8,32,64],required=True)
    args=parser.parse_args();out=PHASE/f"voices-{args.voices}-implementation";out.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="offline_parameter_multivoice_ddr_mixer_rtl",voices=args.voices,hardware_verified=False,limit="Internal registered paths; external PS/DDR and board timing require hardware validation")
    try:
        if args.voices!=1:
            previous={8:1,32:8,64:32}[args.voices]
            predecessor=json.loads((PHASE/f"voices-{previous}-implementation/summary.json").read_text(encoding="utf-8"))
            assert predecessor["success"] and predecessor["scope"]==report["scope"]
            shared=PHASE/"voices-1-implementation"
            for unit in ["xp3_parameter_voice","pcm_parameter_dma","pcm_mixer","pcm_frame_fifo","pcm_sample_fetcher","pcm_sample_cache"]:
                dependencies=[ROOT/"hardware/rtl"/(unit+".sv")]
                if unit=="xp3_parameter_voice":
                    dependencies += [ROOT/"hardware/rtl"/(name+".sv") for name in ["xp3_sample_pkg","xp3_voice_state","xp3_interpolate","xp3_wave_source","xp3_filter_tva","xp3_pair_filter"]]
                    dependencies.append(ROOT/"hardware/rtl/xp3_interpolation.mem")
                assert (shared/(unit+"_synthesis.dcp")).stat().st_mtime>=max(p.stat().st_mtime for p in dependencies), "Changed shared RTL requires rebuilding level 1"
        log=run("vivado.bat",["-mode","batch","-source",str(ROOT/"hardware/synth/parameter_multivoice.tcl"),"-notrace","-tclargs",str(args.voices)],out)
        assert f"MULTIVOICE_IMPLEMENTATION_COMPLETE voices={args.voices}" in log
        report.update(success=True,core=inspect(out))
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally: (out/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
