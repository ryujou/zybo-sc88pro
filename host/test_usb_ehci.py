"""Exercise the generated EHCI completion code with hardware token/error injection."""
import os
import json
from pathlib import Path
import subprocess
from prepare_usb_host import prepare_ehci

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/verification/offline-player/phase-04/usb-ehci"
SOURCE = r'''
#include "tusb.h"
#include "host/hcd.h"
#include "sc88_storage.h"
#include "ehci.h"
#include <assert.h>
#include <string.h>
struct sc88_storage_stats sc88_storage_stats;
static unsigned events, result, bytes, flushes;
static const void *flushed[8];
bool hcd_dcache_invalidate(const void *p, uint32_t n) {(void)p;(void)n;return true;}
bool hcd_dcache_clean(const void *p, uint32_t n) {(void)n;flushed[flushes++]=p;return true;}
bool hcd_dcache_clean_invalidate(const void *p, uint32_t n) {return hcd_dcache_clean(p,n);}
void hcd_event_handler(const hcd_event_t *e, bool isr) {
    assert(isr && e->event_id==HCD_EVENT_XFER_COMPLETE);
    ++events;result=e->xfer_complete.result;bytes=e->xfer_complete.len;
}
static void qhd_remove_qtd(ehci_qhd_t *qhd);
@FUNCTIONS@
static ehci_qhd_t q;
static ehci_qtd_t td;
static void setup(void) {
    memset(&q,0,sizeof(q));memset(&td,0,sizeof(td));
    memset(&sc88_storage_stats,0,sizeof(sc88_storage_stats));events=flushes=0;
    td.used=1;td.expected_bytes=8192;td.total_bytes=4096;td.pid=EHCI_PID_IN;
    q.attached_qtd=&td;q.dev_addr=1;q.ep_number=1;
    q.qtd_overlay.halted=1;q.qtd_overlay.xact_err=1;
    q.qtd_overlay.total_bytes=4096;q.qtd_overlay.data_toggle=1;
    q.qtd_overlay.current_page=2;q.qtd_overlay.pid=EHCI_PID_IN;
    q.qtd_overlay.buffer[0]=0x12345800;q.qtd_overlay.buffer[2]=0x12347000;
}
int main(void) {
    setup();
    for(unsigned i=1;i<=31;++i) {
        flushes=0;q.qtd_overlay.active=0;q.qtd_overlay.halted=1;
        q.qtd_overlay.xact_err=1;q.qtd_overlay.err_count=0;
        qhd_xfer_complete_isr(&q);
        assert(!events && q.attached_qtd==&td && q.xact_retries==i);
        assert(q.qtd_overlay.active && q.qtd_overlay.err_count==3);
        assert(!q.qtd_overlay.halted && !q.qtd_overlay.xact_err);
        assert(q.qtd_overlay.total_bytes==4096 && q.qtd_overlay.current_page==2 && q.qtd_overlay.data_toggle);
        assert(q.qtd_overlay.buffer[0]==0x12345800 && q.qtd_overlay.buffer[2]==0x12347000);
        assert(td.total_bytes==4096 && td.current_page==2 && td.data_toggle);
        assert(flushes==2 && flushed[0]==&td && flushed[1]==&q);
    }
    assert(sc88_storage_stats.xact_retries==31 && sc88_storage_stats.max_xact_retries==31);
    q.qtd_overlay.active=0;q.qtd_overlay.halted=1;q.qtd_overlay.xact_err=1;q.qtd_overlay.err_count=0;
    qhd_xfer_complete_isr(&q);
    assert(events==1 && result==XFER_RESULT_FAILED && bytes==4096 && !q.attached_qtd && !td.used);
    assert(sc88_storage_stats.xact_exhausted==1 && sc88_storage_stats.xact_retries==31);
    for(unsigned kind=0;kind<3;++kind) {
        setup();
        if(kind==0) {q.qtd_overlay.xact_err=0;q.qtd_overlay.err_count=3;}
        if(kind==1) q.qtd_overlay.babble_err=1;
        if(kind==2) q.qtd_overlay.buffer_err=1;
        qhd_xfer_complete_isr(&q);
        assert(events==1 && !sc88_storage_stats.xact_retries);
        assert(result==(kind==0?XFER_RESULT_STALLED:XFER_RESULT_FAILED));
    }
    setup();q.qtd_overlay.active=1;qhd_xfer_complete_isr(&q);assert(!events && !q.xact_retries);
    setup();q.attached_qtd=NULL;qhd_xfer_complete_isr(&q);assert(!events && !q.xact_retries);
    setup();qhd_xfer_complete_isr(&q);
    q.qtd_overlay.active=0;td.total_bytes=0;qhd_xfer_complete_isr(&q);
    assert(events==1 && result==XFER_RESULT_SUCCESS && bytes==8192);
    setup();q.xact_retries=31;qhd_attach_qtd(&q,&td);assert(q.xact_retries==0);
    return 0;
}
'''


def main():
    source = prepare_ehci(OUT)
    code = source.read_text(encoding="utf-8")
    functions = []
    for signature in ["static void qhd_attach_qtd(", "static void qhd_remove_qtd(", "void qhd_xfer_complete_isr("]:
        start = code.rindex(signature)
        functions.append(code[start:code.index("\n}", start) + 2])
    # Only the native pointer padding differs on the x64 test host. ARM builds
    # retain the upstream 64-byte hardware-layout assertion unchanged.
    header = source.with_suffix(".h").read_text(encoding="utf-8")
    header = header.replace("sizeof(ehci_qhd_t) == 64", "sizeof(ehci_qhd_t) == (sizeof(void*) == 4 ? 64 : 96)")
    (OUT / "ehci.h").write_text(header, encoding="utf-8")
    (OUT / "test.c").write_text(SOURCE.replace("@FUNCTIONS@", "\n".join(functions)), encoding="utf-8")
    cc = str(Path(os.environ["VIVADO_ROOT"]) / "tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe")
    command = [cc, "-std=c11", "-O2", "-I", ROOT / "software/ps", "-I", ROOT / "external/tinyusb/src",
               OUT / "test.c", "-o", OUT / "test.exe"]
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True)
    (OUT / "compile.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    result.check_returncode()
    subprocess.run([str(OUT / "test.exe")], check=True)
    report = dict(success=True, hardware_verified=False, scope="EHCI_completion_token_injection",
                  checks=["31_rearms_then_failure", "remaining_page_toggle_preserved", "cache_publish_order",
                          "STALL_not_retried", "babble_not_retried", "buffer_error_not_retried",
                          "active_or_detached_ignored", "success_after_recovery", "new_transfer_resets_limit"])
    (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
