"""Build and inspect the complete original-Zybo PS/PL design, including debug cores."""
import argparse
import json
import re
import zipfile
from phase4 import ROOT,OUT
from test_filter_tva import run


def inspect(out):
    utilization=(out/"utilization-hierarchical.rpt").read_text(encoding="utf-8")
    assert re.search(r"Design State\s*:\s*(?:(?:Fully )?Routed|Physopt postRoute)",utilization) and "xc7z010clg400-1" in utilization
    if "Physopt postRoute" in utilization:
        route=(out/"route-status.rpt").read_text(encoding="utf-8")
        counts={key:int(value) for key,value in re.findall(r"# of (routable nets|fully routed nets|nets with routing errors)\.+\s*:\s*(\d+)",route)}
        assert counts["routable nets"]==counts["fully routed nets"]>0 and counts["nets with routing errors"]==0,"Incomplete board routing"
    row=re.search(r"^\| sc88_wrapper\s*\|\s*\(top\)\s*\|([^\n]+)",utilization,re.M)
    assert row,"Missing complete-device resource row"
    values=[int(value.strip()) for value in row[1].split("|") if value.strip()]
    assert len(values)==8
    resources=dict(LUT=values[0],FF=values[4],BRAM36=values[5],BRAM18=values[6],DSP=values[7])
    assert resources["LUT"]<=17600 and resources["FF"]<=35200 and resources["DSP"]<=80
    assert resources["BRAM36"]*2+resources["BRAM18"]<=120
    for core in ["logic_ila","audio_ila"]:
        assert re.search(rf"^\|\s+{core}\s*\|",utilization,re.M),f"Missing {core} from complete-device resources"
    timing=(out/"timing-summary.rpt").read_text(encoding="utf-8")
    row=re.search(r"WNS\(ns\).*?\n\s*-.*?\n\s*([^\n]+)",timing)
    assert row,"Missing full-device timing summary"
    times=list(map(float,row[1].split()))
    assert len(times)==12 and all(times[i]>=0 for i in [0,4,8]),"Setup/hold/pulse-width violation"
    assert all(times[i]==0 for i in [1,2,5,6,9,10]),"Failing timing endpoints"
    for check in ["no_clock","unconstrained_internal_endpoints","multiple_clock","generated_clocks","loops","latch_loops"]:
        assert f"checking {check} (0)" in timing,f"Board timing check failed: {check}"
    assert "codec_bclk" in timing,"Codec interface timing is absent"
    drc=(out/"drc.rpt").read_text(encoding="utf-8")
    assert "Report DRC" in drc and "REPORT SUMMARY" in drc and re.search(r"Checks found:\s*\d+",drc),"Missing board DRC report"
    assert not re.search(r"\|\s*(?:Error|Critical Warning)\s*\|",drc),"Board DRC failure"
    cdc=(out/"cdc.rpt").read_text(encoding="utf-8")
    assert "report_cdc" in cdc and "CDC" in cdc,"Missing board CDC report"
    assert not re.search(r"\|\s*Critical\s*\||^\s*CDC-\d+\s+Critical\b",cdc,re.M),"Board CDC critical crossing"
    assert (out/"sc88-routed.dcp").stat().st_size and (out/"sc88.ltx").stat().st_size
    with zipfile.ZipFile(out/"sc88.xsa") as archive:
        bits=[name for name in archive.namelist() if name.endswith(".bit")]
        assert len(bits)==1 and archive.read(bits[0])==(out/"sc88.bit").read_bytes()
    return dict(**resources,WNS_ns=times[0],WHS_ns=times[4],WPWS_ns=times[8])


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--inspect-only",action="store_true",help="inspect an already completed build")
    args=parser.parse_args()
    out=OUT/"board";out.mkdir(parents=True,exist_ok=True)
    summary=dict(success=False,scope="full_Zybo_PS_PL_with_two_clock_domain_ILAs",hardware_verified=False)
    try:
        if not args.inspect_only:
            log=run("vivado.bat",["-mode","batch","-nojournal","-source",str(ROOT/"hardware/board/build.tcl")],out)
            assert "SC88_BOARD_ARTIFACTS_COMPLETE" in log,"Board build did not complete"
        summary.update(success=True,device=inspect(out))
        print(json.dumps(summary))
    except Exception as error:
        summary["error"]=str(error);raise
    finally:(out/"summary.json").write_text(json.dumps(summary,indent=2)+"\n",encoding="utf-8")


if __name__=="__main__":main()
