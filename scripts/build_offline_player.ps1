$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $root 'reference/gearmulator-lock.json') -Raw -Encoding utf8 | ConvertFrom-Json
$upstream = Join-Path $root 'external/gearmulator'
$commit = & git -C $upstream rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit.Trim() -ne $lock.commit) { throw 'Upstream commit differs from lock.' }
$changes = & git -C $upstream status --porcelain
if ($changes) { throw 'Pinned reference is modified.' }
& py -3 -X utf8 (Join-Path $root 'host/prepare_offline_player.py')
if ($LASTEXITCODE -ne 0) { throw 'Parameter boundary generation failed.' }
$build = Join-Path $root 'build/offline-player'
& cmake -S (Join-Path $root 'host/reference_runner') -B $build -G 'Visual Studio 17 2022' -A x64 -DSC88_BUILD_PARAMETERS=ON
if ($LASTEXITCODE -ne 0) { throw 'Parameter player configuration failed.' }
& cmake --build $build --config Release --target sc88_parameter_export sc88_parameter_replay sc88_offline_irq_0 sc88_offline_irq_1 sc88_offline_irq_2 --parallel 8
if ($LASTEXITCODE -ne 0) { throw 'Parameter player build failed.' }
