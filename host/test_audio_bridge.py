"""Run the actual XPM CDC/FIFO simulation with independent 100 MHz and audio clocks."""
import json
from phase4 import ROOT,OUT
from test_filter_tva import run,VIVADO


def main():
    out=OUT/"audio-bridge";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        xpm=VIVADO.parent/"data/ip/xpm"
        sources=[xpm/name/"hdl"/(name+".sv") for name in ["xpm_cdc","xpm_memory","xpm_fifo"]]
        sources += [ROOT/"hardware/board"/name for name in ["pcm_i2s.sv","pcm_audio_bridge.sv"]]
        sources.append(ROOT/"hardware/sim/tb_audio_bridge.sv")
        sources.append(VIVADO.parent/"data/verilog/src/glbl.v")
        run("xvlog.bat",["--sv",*[str(p) for p in sources]],out)
        run("xelab.bat",["tb_audio_bridge","glbl","-s","audio_bridge","--debug","typical","-L","unisims_ver"],out)
        log=run("xsim.bat",["audio_bridge","-runall"],out)
        assert "AUDIO_BRIDGE_PASS checks=10 full_depth=33 pause_resume=1 reset_positions=8 due_order=1 finish=1" in log and "Fatal:" not in log and "Error:" not in log,"Audio CDC simulation failed"
        summary.update(success=True,checks=10,reset_positions=8,fifo_storage_depth=32,fifo_effective_depth=33,finite_single_frame=True)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
