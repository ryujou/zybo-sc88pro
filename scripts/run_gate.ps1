param(
    [ValidateRange(0,6)][int]$Phase = 0,
    [ValidateSet('A','B','C','D')][string]$Step = 'D',
    [string]$RomPath = '',
    [switch]$Offline,
    [switch]$LegacyBaseline
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gateScript = if (-not $LegacyBaseline -and $Phase -eq 1) {
    'host/offline_phase1.py'
} elseif (-not $LegacyBaseline -and $Phase -ge 2) {
    if ($Phase -eq 2) { 'host/offline_phase2.py' }
    elseif ($Phase -eq 3) { 'host/offline_phase3.py' }
    elseif ($Phase -eq 4) { 'host/offline_phase4.py' }
    else { throw "Offline-player Phase $Phase has not been adapted; legacy evidence cannot pass the current parameter-player scope." }
} else { switch ($Phase) {
    1 { 'host/phase1.py' }
    2 { 'host/phase2_rtl.py' }
    3 { 'host/phase3.py' }
    4 { 'host/phase4.py' }
    default { 'host/phase0.py' }
} }
$gateArgs = @('--phase', $Phase, '--step', $Step, '--rom-path', $RomPath)
if ($Offline) { $gateArgs += '--offline' }
& py -3 -X utf8 (Join-Path $root $gateScript) @gateArgs
exit $LASTEXITCODE
