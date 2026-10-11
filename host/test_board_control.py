"""Full board module AXI-Lite setup, DMA audio playback and accepted-AXI reset drain."""
import json
import shutil
from phase4 import ROOT,OUT
from test_voice import RTL
from test_filter_tva import run,VIVADO


def main():
    out=OUT/"board-control";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,hardware_verified=False)
    try:
        for table in ["xp3_pitch.mem","xp3_interpolation.mem"]:shutil.copyfile(ROOT/"hardware/rtl"/table,out/table)
        sources=[ROOT/"hardware/rtl"/(name+".sv") for name in RTL+["pcm_mixer","pcm_frame_fifo","pcm_sample_fetcher","pcm_sample_cache","pcm_voice_scheduler"]]
        xpm=VIVADO.parent/"data/ip/xpm"
        sources += [xpm/name/"hdl"/(name+".sv") for name in ["xpm_cdc","xpm_memory","xpm_fifo"]]
        sources += [ROOT/"hardware/board"/(name+".sv") for name in ["pcm_commands","pcm_results","pcm_i2s","pcm_audio_bridge","pcm_synth","pcm_block_queue","pcm_block_dma","pcm_transport","pcm_registers","pcm_axi_control","pcm_board"]]
        sources += [ROOT/"hardware/sim/tb_board_control.sv",VIVADO.parent/"data/verilog/src/glbl.v"]
        run("xvlog.bat",["--sv",*[str(p) for p in sources]],out)
        run("xelab.bat",["tb_board_control","glbl","-s","board_control","--debug","typical","-L","unisims_ver"],out)
        log=run("xsim.bat",["board_control","-runall"],out)
        assert "BOARD_CONTROL_PASS checks=8 playback_frames=4 accepted_read_reset=1" in log and "Fatal:" not in log and "Error:" not in log,"Board control path comparison failed"
        summary.update(success=True,checks=8,playback_frames=4,accepted_read_reset=True,invalid_descriptors_rejected=4)
        print(json.dumps(summary))
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
