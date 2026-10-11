$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $root 'reference/gearmulator-lock.json') -Raw | ConvertFrom-Json
$upstream = Join-Path $root 'external/gearmulator'
if (-not (Test-Path -LiteralPath (Join-Path $upstream '.git'))) {
    & git clone --no-checkout --filter=blob:none $lock.repository $upstream
    if ($LASTEXITCODE -ne 0) { throw 'Gearmulator clone failed.' }
    & git -C $upstream checkout --detach $lock.commit
    if ($LASTEXITCODE -ne 0) { throw 'Pinned Gearmulator checkout failed.' }
}
$commit = & git -C $upstream rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit.Trim() -ne $lock.commit) { throw 'Gearmulator commit differs from lock.' }
$changes = & git -C $upstream status --porcelain
if ($changes) { throw 'Gearmulator reference worktree is modified.' }
$build = Join-Path $root 'build/reference'
& cmake -S (Join-Path $root 'host/reference_runner') -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Reference configuration failed.' }
& cmake --build $build --config Release --target sc88_reference_runner --parallel 8
if ($LASTEXITCODE -ne 0) { throw 'Reference build failed.' }
