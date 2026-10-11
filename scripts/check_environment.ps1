param([string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root 'build/verification/phase-00/environment.json' }
$vivado = $env:VIVADO_ROOT
$vitis = $env:VITIS_ROOT
if (-not $vivado -or -not $vitis) { throw 'Set VIVADO_ROOT and VITIS_ROOT to the installed 2025.2 tool directories.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'MSVC x64 build tools not found.' }
$msvc = Get-ChildItem -LiteralPath (Join-Path $vs 'VC/Tools/MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$commands = @(
    @{ name='git'; path=(Get-Command git).Source; args=@('--version') },
    @{ name='python'; path=(Get-Command py).Source; args=@('-3','--version') },
    @{ name='cmake'; path=(Get-Command cmake).Source; args=@('--version') },
    @{ name='ninja'; path=(Get-Command ninja).Source; args=@('--version') },
    @{ name='msvc'; path=(Join-Path $msvc.FullName 'bin/Hostx64/x64/cl.exe'); args=@() },
    @{ name='vivado'; path=(Join-Path $vivado 'bin/vivado.bat'); args=@('-mode','batch','-nojournal','-nolog','-source',(Join-Path $PSScriptRoot 'environment_smoke.tcl')) },
    @{ name='vitis_hls'; path=(Join-Path $vitis 'bin/vitis-run.bat'); args=@('--version') },
    @{ name='xsct'; path=(Join-Path $vitis 'bin/xsct.bat'); args=@((Join-Path $PSScriptRoot 'xsct_smoke.tcl')) },
    @{ name='xsim'; path=(Join-Path $vivado 'bin/xsim.bat'); args=@('--version') }
)
$results = @(@{ name='powershell'; path=(Get-Process -Id $PID).Path; exit_code=0; output=$PSVersionTable.PSVersion.ToString() })
$auditDirectory = Join-Path $root 'build/tool-audit'
New-Item -ItemType Directory -Path $auditDirectory -Force | Out-Null
Push-Location $auditDirectory
try {
foreach ($command in $commands) {
    if (-not (Test-Path -LiteralPath $command.path)) { throw "Missing tool: $($command.path)" }
    $arguments = $command.args
    $lines = & $command.path @arguments 2>&1
    $code = $LASTEXITCODE
    $results += @{ name=$command.name; path=$command.path; exit_code=$code; output=($lines | Out-String).Trim() }
    Write-Host "$($command.name): exit $code"
}
} finally {
    Pop-Location
}
$result = @{ powershell_major=$PSVersionTable.PSVersion.Major; visual_studio=$vs.Trim(); tools=$results; success=($PSVersionTable.PSVersion.Major -ge 7 -and @($results | Where-Object exit_code -ne 0).Count -eq 0) }
New-Item -ItemType Directory -Path (Split-Path -Parent $Out) -Force | Out-Null
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Out -Encoding utf8
if (-not $result.success) { throw 'Environment audit failed; inspect environment.json.' }
