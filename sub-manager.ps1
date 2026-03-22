# sub-manager.ps1
# PowerShell launcher for Sub Manager on Windows
# Usage: .\sub-manager.ps1 [args...]
#
# Locates Git Bash (bash.exe) and forwards all arguments to sub-manager.sh.
# Supports interactive use and all CLI flags (--cron-check, --bot, etc.).

$ErrorActionPreference = "Stop"

# ── Find bash.exe ──────────────────────────────────────────────────────────────
$bashCandidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LocalAppData\Programs\Git\bin\bash.exe"
)

$bash = $null
foreach ($c in $bashCandidates) {
    if (Test-Path $c) { $bash = $c; break }
}

if (-not $bash) {
    # Try PATH
    $found = Get-Command bash -ErrorAction SilentlyContinue
    if ($found) { $bash = $found.Source }
}

if (-not $bash) {
    Write-Error "未找到 bash.exe，请先安装 Git for Windows: https://git-scm.com/download/win"
    exit 1
}

# ── Locate sub-manager.sh next to this script ─────────────────────────────────
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$subManager = Join-Path $scriptDir "sub-manager.sh"

if (-not (Test-Path $subManager)) {
    Write-Error "未找到 sub-manager.sh，请确保与 sub-manager.ps1 在同一目录"
    exit 1
}

# Convert Windows path to Unix path for bash
$subManagerUnix = & $bash -c "cygpath -u '$($subManager.Replace("'","'\''"))'" 2>$null
if (-not $subManagerUnix) {
    # Fallback: manual conversion
    $subManagerUnix = $subManager -replace '\\', '/' -replace '^([A-Za-z]):', { "/$($_.Groups[1].Value.ToLower())" }
}

# ── Run ───────────────────────────────────────────────────────────────────────
$bashArgs = @("-l", $subManagerUnix) + $args
& $bash @bashArgs
exit $LASTEXITCODE
