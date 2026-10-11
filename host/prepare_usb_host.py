"""Build the fixed TinyUSB EHCI source with bounded transaction-error recovery."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def prepare_ehci(output):
    upstream = ROOT / "external/tinyusb/src/portable/ehci"
    output = Path(output) / "ehci"
    output.mkdir(parents=True, exist_ok=True)
    header = (upstream / "ehci.h").read_text(encoding="utf-8")
    old = "  uint8_t TU_RESERVED[4];"
    assert header.count(old) == 1
    header = header.replace(old, "  uint8_t xact_retries;\n  uint8_t TU_RESERVED[3];")
    source = (upstream / "ehci.c").read_text(encoding="utf-8")
    old = '    if ( qtd_overlay->halted ) {\n      if (qtd_overlay->xact_err'
    replacement = '''    // Resume the halted transaction with its remaining bytes/page/toggle intact.
    // Linux EHCI likewise permits 31 software re-arms after hardware CERR exhaustion.
    if (qtd_overlay->halted && qtd_overlay->xact_err && !qtd_overlay->err_count &&
        !qtd_overlay->buffer_err && !qtd_overlay->babble_err) {
      if (qhd->xact_retries < 31) {
        ++qhd->xact_retries;
        ++sc88_storage_stats.xact_retries;
        if (qhd->xact_retries > sc88_storage_stats.max_xact_retries)
          sc88_storage_stats.max_xact_retries = qhd->xact_retries;
        ehci_qtd_t *td = qhd->attached_qtd;
        hcd_dcache_invalidate(td, sizeof(*td));
        uint32_t token = ((volatile uint32_t *)qtd_overlay)[2];
        token = (token & ~0x48u) | 0xc80u; // clear HALTED/XACTERR; set ACTIVE/CERR=3
        ((volatile uint32_t *)td)[2] = token;
        hcd_dcache_clean_invalidate(td, sizeof(*td));
        ((volatile uint32_t *)qtd_overlay)[2] = token;
        hcd_dcache_clean_invalidate(qhd, sizeof(*qhd));
        return;
      }
      ++sc88_storage_stats.xact_exhausted;
    }
    if ( qtd_overlay->halted ) {
      if (qtd_overlay->xact_err'''
    assert source.count(old) == 1
    source = source.replace(old, replacement)
    old = "  qhd->attached_qtd = qtd;"
    assert source.count(old) == 1
    source = source.replace(old, "  qhd->xact_retries = 0;\n" + old)
    source = '#include "sc88_storage.h"\n' + source
    (output / "ehci.h").write_text(header, encoding="utf-8")
    (output / "ehci.c").write_text(source, encoding="utf-8")
    return output / "ehci.c"
