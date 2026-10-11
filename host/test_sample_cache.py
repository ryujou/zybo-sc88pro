"""Verify BRAM cache plus AXI fetcher: byte hits, per-voice ways, prefetch and reset."""
import json
import re

from phase3 import ROOT, OUT as PHASE
from test_filter_tva import run

OUT=PHASE/"sample-cache"


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    report=dict(success=False,scope="BRAM_cache_and_AXI_fetcher",hardware_verified=False)
    try:
        run("xvlog.bat",["--sv",*[str(ROOT/path) for path in ["hardware/rtl/pcm_sample_fetcher.sv","hardware/rtl/pcm_sample_cache.sv","hardware/sim/tb_sample_cache.sv"]]],OUT)
        run("xelab.bat",["tb_sample_cache","-s","sample_cache","--debug","typical"],OUT)
        log=run("xsim.bat",["sample_cache","-runall"],OUT)
        match=re.search(r"SAMPLE_CACHE_PASS reads=(\d+) one_cycle_hits=(\d+) two_cycle_BRAM_hits=(\d+) flush_positions=(\d+)",log)
        assert match and "Fatal:" not in log, "Cache/fetcher comparison did not pass"
        report.update(success=True,reads=int(match[1]),one_cycle_hits=int(match[2]),two_cycle_BRAM_hits=int(match[3]),flush_positions=int(match[4]),limit="Cache/fetcher component simulation; integrated deadline and hardware timing remain unverified")
        print(f"SAMPLE_CACHE_COMPONENT_PASS reads={match[1]} one_cycle_hits={match[2]} two_cycle_BRAM_hits={match[3]} flush_positions={match[4]}")
    except Exception as error:
        report["error"]=str(error);raise
    finally: (OUT/"summary.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__": main()
