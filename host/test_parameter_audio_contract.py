"""Check current Codec code and I2S pins independently for the parameter board route."""
import os
from fractions import Fraction
import json
from pathlib import Path
import re
import subprocess

import test_i2s

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/verification/offline-player/phase-04/audio-contract"
CODEC=r'''
#include "sc88_codec.h"
#include <assert.h>
static const unsigned sequence[][2]={{15,0},{6,0x77},{0,0x97},{1,0x97},{2,0x79},{3,0x79},
    {4,0x10},{5,0},{7,2},{8,0x18},{9,1},{6,0x67}};
static unsigned writes,delays;
static int failure=-1;
int sc88_i2c_write(uint8_t address,const uint8_t *bytes,unsigned count) {
    assert(address==0x1a && count==2 && writes<12);
    assert(bytes[0]==((sequence[writes][0]<<1)|(sequence[writes][1]>>8)));
    assert(bytes[1]==(sequence[writes][1]&255));
    if(writes>=10) assert(delays==1);
    return (int)writes++==failure?-77:0;
}
void sc88_delay_us(unsigned us) { assert(us==75000 && writes==10 && !delays);++delays; }
int main(void) {
    assert(!sc88_codec_init() && writes==12 && delays==1);
    for(failure=0;failure<12;++failure) {
        writes=delays=0;
        assert(sc88_codec_init()==-77 && writes==(unsigned)failure+1);
    }
    return 0;
}
'''


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="parameter_board_Codec_I2S_contract",hardware_verified=False)
    (OUT/"summary.json").write_text(json.dumps(report),encoding="utf-8")
    design=(ROOT/"hardware/board/design.tcl").read_text(encoding="utf-8")
    def setting(name):
        return Fraction(re.search(r"CONFIG\."+name+r"\s+\{([\d.]+)\}",design)[1])
    input_hz=setting("PRIM_IN_FREQ")*1000000
    divisor=setting("MMCM_DIVCLK_DIVIDE")
    multiplier=setting("MMCM_CLKFBOUT_MULT_F")
    output_divisor=setting("MMCM_CLKOUT0_DIVIDE_F")
    assert (input_hz,divisor,multiplier,output_divisor)==(125000000,8,Fraction("39.125"),Fraction("49.750"))
    mclk=input_hz/divisor*multiplier/output_divisor
    ppm=(mclk/12288000-1)*1000000
    assert abs(ppm)<1
    (OUT/"codec_test.c").write_text(CODEC,encoding="utf-8")
    compiler=str(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe")
    result=subprocess.run([compiler,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(ROOT/"software/ps"),
                           str(OUT/"codec_test.c"),str(ROOT/"software/ps/sc88_codec.c"),"-o",str(OUT/"codec_test.exe")],capture_output=True,text=True)
    (OUT/"codec-compile.log").write_text(result.stdout+result.stderr,encoding="utf-8");result.check_returncode()
    subprocess.run([str(OUT/"codec_test.exe")],check=True)
    test_i2s.OUT=OUT
    test_i2s.main()
    i2s=json.loads((OUT/"i2s/summary.json").read_text(encoding="utf-8"));assert i2s["success"]
    report.update(success=True,codec_I2C_failures=12,i2s=i2s,
                  calculated_mclk_hz=float(mclk),calculated_bclk_hz=float(mclk/6),
                  calculated_sample_hz=float(mclk/384),MMCM_error_ppm=float(ppm),
                  oscillator_tolerance="Not included; actual board clock remains to be measured",
                  datasheet="https://www.analog.com/media/en/technical-documentation/data-sheets/SSM2603.pdf",
                  boot_sequence="https://ez.analog.com/audio/a/documents/DO11695/ssm2603-ssm2604-boot-sequence")
    (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report),flush=True)


if __name__=="__main__":main()
