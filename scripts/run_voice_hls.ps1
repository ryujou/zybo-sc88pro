param([Parameter(Mandatory)][ValidateSet('csim','synthesis','cosim','implementation')][string]$Stage)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $root
$env:XP3_HLS_STAGE=$Stage
$log=Join-Path $root "build/verification/phase-02/logs/hls-$Stage.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log -Parent),(Join-Path $root "build/verification/phase-02/$Stage") | Out-Null
& (Join-Path $env:VITIS_ROOT 'bin/vitis-run.bat') --mode hls --tcl hls/run_hls.tcl 2>&1 | Tee-Object -FilePath $log
$code=$LASTEXITCODE
$result=Get-Content -LiteralPath $log -Raw -Encoding utf8
if ($code -ne 0 -or $result -match '(?m)^ERROR:') { throw "HLS $Stage failed; see $log" }
$marker=@{csim='CSim done with 0 errors';synthesis='Finished Command csynth_design';cosim='C/RTL co-simulation finished: PASS';implementation='Finished Command export_design'}[$Stage]
if (-not $result.Contains($marker)) { throw "HLS $Stage completion evidence missing; see $log" }
