# ============================================================================
# Hermes Portable - Venv Self-Heal (Windows PowerShell)
# ============================================================================
# Makes the venv independent of its drive letter / absolute path. Runs on every
# launch: idempotent, sub-second, fully local, no network access.
#
# It performs two repairs that remove the absolute paths a venv bakes in at
# build time:
#   1. Rewrite pyvenv.cfg's `home=` to the current Python directory.
#      -> Fixes the venv being unable to locate its base interpreter after the
#         drive letter changes.
#   2. Remove the editable-install (`__editable__*`) artifacts, whose finder
#      hard-codes the build machine's absolute paths.
#      -> The source is instead provided via PYTHONPATH in launch.bat, so it
#         travels with the folder.
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = "Stop"

$RuntimeDir = Join-Path $Root ".cache\runtimes\windows-x64"
$VenvDir    = Join-Path $RuntimeDir "venv"
$PythonDir  = Join-Path $RuntimeDir "python"
$Cfg        = Join-Path $VenvDir "pyvenv.cfg"
$Site       = Join-Path $VenvDir "Lib\site-packages"

# ---- 1. Fix pyvenv.cfg `home` ----
if (Test-Path $Cfg) {
    $lines   = Get-Content $Cfg
    $changed = $false
    $out = foreach ($line in $lines) {
        if ($line -match '^\s*home\s*=') {
            $new = "home = $PythonDir"
            if ($line -ne $new) { $changed = $true }
            $new
        } else {
            $line
        }
    }
    if ($changed) {
        # ASCII without BOM so Python can parse pyvenv.cfg correctly.
        Set-Content -Path $Cfg -Value $out -Encoding ascii
    }
}

# ---- 2. Remove editable-install artifacts (source of absolute paths) ----
if (Test-Path $Site) {
    Get-ChildItem $Site -Filter "__editable__*hermes*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

exit 0
