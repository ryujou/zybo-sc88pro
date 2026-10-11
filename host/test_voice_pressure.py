"""Worst source refill at an exponent-boundary endpoint, from independent XP progression."""
import json
import re
import shutil
import subprocess
import test_voice as voice
from test_filter_tva import ROOT,run,rows

OUT=ROOT/"build/verification/phase-02-rtl/voice-pressure"

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(scope="voice_endpoint_pressure",success=False,hardware_verified=False)
    try:
        reference=OUT/"reference"
        subprocess.run([str(ROOT/"build/voice-reference/Release/sc88_voice_vectors.exe"),str(reference),"--pressure"],check=True,capture_output=True)
        voice.OUT=OUT;voice.vectors(reference,[r["case"] for r in rows(reference/"manifest.csv")])
        for name in ["xp3_pitch.mem","xp3_interpolation.mem"]:shutil.copyfile(ROOT/"hardware/rtl"/name,OUT/name)
        run("xvlog.bat",["--sv",*[str(ROOT/"hardware/rtl"/(name+".sv")) for name in voice.RTL],str(ROOT/"hardware/sim/tb_voice.sv")],OUT)
        run("xelab.bat",["tb_voice","-s","voice","--debug","typical"],OUT)
        log=run("xsim.bat",["voice","-runall","-testplusarg","pressure"],OUT)
        match=re.search(r"VOICE_SYNTHETIC_PASS cases=30 frames=7680 single_cycles=(\d+) pair_cycles=(\d+)",log)
        assert match and "Fatal:" not in log
        report.update(numeric_match=True,single_cycles=int(match[1]),pair_cycles=int(match[2]))
        assert int(match[1])<=44 and int(match[2])<=88, "Exponent-boundary endpoint exceeds 44/88 cycles"
        report["success"]=True
        print(json.dumps(report))
    except Exception as error:
        report["error"]=str(error);raise
    finally:(OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")

if __name__=="__main__":main()
