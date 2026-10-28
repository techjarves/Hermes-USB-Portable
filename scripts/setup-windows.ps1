# ============================================================================
# Hermes Portable - Windows Runtime Setup
# ============================================================================
# Downloads and installs portable Python, Node.js, uv, ripgrep, Git,
# clones Hermes source, creates venv, and installs dependencies.
# ============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$CacheDir   = Join-Path $Root ".cache"
$RuntimeDir = Join-Path $CacheDir "runtimes\windows-x64"
$SrcDir     = Join-Path $Root "src"
$BinDir     = Join-Path $RuntimeDir "bin"
$TempDir    = Join-Path $RuntimeDir "_temp"

New-Item -ItemType Directory -Force -Path $RuntimeDir, $SrcDir, $BinDir, $TempDir | Out-Null

# ---------------------------------------------------------------------------
# Download URLs (pinned for reliability)
# ---------------------------------------------------------------------------
# portable-v1.9.0: Python 3.14.9 (python-build-standalone 20261021). hermes-agent
# v0.22.x marks its core deps python_version >= '3.14'; 3.13 cannot run it.
$PythonUrl  = "https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.14.9+20261021-x86_64-pc-windows-msvc-install_only.tar.gz"
$NodeUrl    = "https://nodejs.org/dist/v24.16.0/node-v24.16.0-win-x64.zip"
$UvUrl      = "https://github.com/astral-sh/uv/releases/download/0.11.21/uv-x86_64-pc-windows-msvc.zip"
$RgUrl      = "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-x86_64-pc-windows-msvc.zip"
$GitUrl     = "https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.1/MinGit-2.53.0-64-bit.zip"
# Hermes Agent source is pinned to VERSION's hermes_agent_ref - the same pin
# setup-unix.sh and both launchers read. The cached zip carries the ref, so a
# new pin downloads fresh source instead of reusing an old source.zip.
$HermesRef = "main"
$verFile = Join-Path $Root "VERSION"
if (Test-Path $verFile) {
    $refLine = Select-String -Path $verFile -Pattern '^hermes_agent_ref:\s*(\S+)' | Select-Object -First 1
    if ($refLine) { $HermesRef = $refLine.Matches[0].Groups[1].Value }
}
if ($HermesRef -eq "main") {
    $SourceUrl = "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.zip"
} else {
    $SourceUrl = "https://github.com/NousResearch/hermes-agent/archive/refs/tags/$HermesRef.zip"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step($msg) {
    Write-Host ""
    Write-Host "[SETUP] $msg" -ForegroundColor Cyan
}

function Write-Done($msg) {
    Write-Host "[OK]    $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "[WARN]  $msg" -ForegroundColor Yellow
}

function Download-File($Url, $OutFile) {
    $name = Split-Path $Url -Leaf
    if (Test-Path $OutFile) {
        $size = (Get-Item $OutFile).Length
        if ($size -gt 0) {
            $sizeMB = [math]::Round($size / 1048576, 2)
            $msg = "        " + $name + " already cached (" + $sizeMB + " MB)."
            Write-Host $msg
            return
        } else {
            Write-Warn ($name + " exists but is 0 bytes - re-downloading ...")
            Remove-Item $OutFile -Force
        }
    }
    $msg1 = "        Downloading " + $name + " ..."
    $msg2 = "        URL: " + $Url
    Write-Host $msg1 -ForegroundColor Cyan
    Write-Host $msg2 -ForegroundColor DarkGray

    # Prefer curl.exe for native progress bar (speed, percent, time left, time spent)
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $curlArgs = @("-L", "-f", "--retry", "3", "--connect-timeout", "30", "--max-time", "600", "-o", $OutFile, $Url)
        & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
            throw "curl.exe failed with exit code " + $LASTEXITCODE + " while downloading " + $name
        }
    } else {
        $ProgressPreference = 'Continue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
        }
        catch {
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
            throw "Failed to download " + $name + ": " + $_
        }
        finally {
            $ProgressPreference = 'Continue'
        }
    }

    # Validate downloaded file
    if (-not (Test-Path $OutFile)) {
        throw "Download succeeded but file not found: " + $OutFile
    }
    $downloadedSize = (Get-Item $OutFile).Length
    if ($downloadedSize -eq 0) {
        Remove-Item $OutFile -Force
        throw "Downloaded file is 0 bytes: " + $name
    }
    $sizeMB = [math]::Round($downloadedSize / 1048576, 2)
    $msgDone = "        Download complete: " + $sizeMB + " MB."
    Write-Host $msgDone -ForegroundColor Green
}

function Extract-TarGz($Archive, $Destination) {
    $label = Split-Path $Archive -Leaf
    Write-Host "        Extracting $label ..." -NoNewline
    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    # Use Windows built-in tar to avoid Git Bash tar path issues.
    # -m (do not restore modification times): the portable drive is exFAT, where
    # bsdtar's post-extract utime() call fails with "Can't restore time: Invalid
    # argument" on every entry and makes tar exit NON-ZERO even though the files
    # extracted fine. That false failure used to abort setup (or trip the slow
    # Expand-Archive fallback). -m skips the mtime restore, so tar exits 0 on
    # exFAT. Windows-specific: setup-unix.sh extracts on a native FS / local-disk
    # stage, so it never hits this. (Verified: node.zip -> exit 1 + 1942 time
    # errors without -m; exit 0 with -m.)
    $winTar = "C:\Windows\System32\tar.exe"
    if (Test-Path $winTar) {
        & $winTar -xzf "$Archive" -C "$Destination" --strip-components=1 -m
    } else {
        & tar.exe -xzf "$Archive" -C "$Destination" --strip-components=1 -m
    }
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
        throw "tar extraction failed for " + $label
    }
    Write-Host " done" -ForegroundColor Green
}

function Extract-Zip($Archive, $Destination) {
    $label = Split-Path $Archive -Leaf
    Write-Host "        Extracting $label ..." -NoNewline
    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    try {
        $extracted = $false
        # -m: skip mtime restore so bsdtar exits 0 on exFAT (see Extract-TarGz).
        # Without it, tar exits non-zero on the exFAT drive (utime EINVAL) and we
        # fall through to Expand-Archive, which then throws on the half-populated
        # destination and aborts setup.
        $winTar = "C:\Windows\System32\tar.exe"
        if (Test-Path $winTar) {
            & $winTar -xf "$Archive" -C "$Destination" -m
            if ($LASTEXITCODE -eq 0) {
                $extracted = $true
            }
        } elseif (Get-Command tar.exe -ErrorAction SilentlyContinue) {
            & tar.exe -xf "$Archive" -C "$Destination" -m
            if ($LASTEXITCODE -eq 0) {
                $extracted = $true
            }
        }

        if (-not $extracted) {
            Expand-Archive -Path $Archive -DestinationPath $Destination -Force
        }

        if (-not (Get-ChildItem $Destination -Force | Select-Object -First 1)) {
            throw "archive extracted with no files"
        }
    } catch {
        Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
        throw "zip extraction failed for " + $label + ": " + $_
    }
    Write-Host " done" -ForegroundColor Green
}

function Move-SubfolderContents($Source, $Dest) {
    $sub = Get-ChildItem $Source -Directory | Select-Object -First 1
    if ($sub) {
        if (Test-Path $Dest) {
            Remove-Item $Dest -Recurse -Force
        }
        Move-Item $sub.FullName $Dest -Force
        Remove-Item $Source -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-DirectoryContents($Source, $Dest) {
    # Replace $Dest with the contents of $Source, tolerating a LOCKED destination.
    # On Windows a file under src\hermes-agent can be held open (antivirus scan,
    # Search indexer, or a still-running hermes during a repair re-run), which makes
    # a plain `Remove-Item $Dest -Recurse -Force` THROW and abort setup. We try the
    # clean remove first, then fall back to deleting whatever children we can, then
    # copy the fresh tree in (Copy-Item merges over any file that couldn't be
    # removed). Adapted from upstream techjarves commit b2904ba ("fix locked source
    # refresh during setup").
    if (Test-Path $Dest) {
        try {
            Remove-Item $Dest -Recurse -Force -ErrorAction Stop
        } catch {
            Get-ChildItem $Dest -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item (Join-Path $Source "*") $Dest -Recurse -Force
}

# ---------------------------------------------------------------------------
# Health check: if ready.flag exists but core files are missing, start fresh
# ---------------------------------------------------------------------------
$readyFlag = Join-Path $RuntimeDir "ready.flag"
if (Test-Path $readyFlag) {
    $coreFiles = @("python\python.exe", "uv\uv.exe", "venv\Scripts\hermes.exe")
    $missing = $coreFiles | Where-Object { -not (Test-Path (Join-Path $RuntimeDir $_)) }
    if ($missing) {
        Write-Warn "ready.flag exists but core files are missing - restarting setup ..."
        Remove-Item $readyFlag -Force
    }
}

# ---------------------------------------------------------------------------
# 1. Portable Python
# ---------------------------------------------------------------------------
Write-Step "Installing portable Python 3.13 ..."
# Archive name carries the version so a bump never reuses an old python.tar.gz.
$pyArchive = Join-Path $RuntimeDir "python-3.14.9.tar.gz"
Get-ChildItem $RuntimeDir -Filter "python*.tar.gz" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $pyArchive } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Download-File $PythonUrl $pyArchive
Extract-TarGz $pyArchive (Join-Path $RuntimeDir "python")
Write-Done "Python ready"

# ---------------------------------------------------------------------------
# 2. Node.js
# ---------------------------------------------------------------------------
Write-Step "Installing Node.js 24 LTS ..."
$nodeArchive = Join-Path $RuntimeDir "node.zip"
Download-File $NodeUrl $nodeArchive
$nodeTemp = Join-Path $TempDir "node"
Extract-Zip $nodeArchive $nodeTemp
Move-SubfolderContents $nodeTemp (Join-Path $RuntimeDir "node")
Write-Done "Node.js ready"

# ---------------------------------------------------------------------------
# 3. uv (Python package manager)
# ---------------------------------------------------------------------------
Write-Step "Installing uv ..."
$uvArchive = Join-Path $RuntimeDir "uv.zip"
Download-File $UvUrl $uvArchive
Extract-Zip $uvArchive (Join-Path $RuntimeDir "uv")
Write-Done "uv ready"

# ---------------------------------------------------------------------------
# 4. ripgrep
# ---------------------------------------------------------------------------
Write-Step "Installing ripgrep ..."
$rgArchive = Join-Path $RuntimeDir "rg.zip"
Download-File $RgUrl $rgArchive
$rgTemp = Join-Path $TempDir "rg"
Extract-Zip $rgArchive $rgTemp
$rgExe = Get-ChildItem $rgTemp -Recurse -Filter "rg.exe" | Select-Object -First 1
if ($rgExe) {
    Copy-Item $rgExe.FullName (Join-Path $BinDir "rg.exe") -Force
    Write-Done "ripgrep ready"
} else {
    Write-Warn "ripgrep exe not found in archive"
}

# ---------------------------------------------------------------------------
# 5. Git (MinGit) - optional
# ---------------------------------------------------------------------------
Write-Step "Installing portable Git (optional) ..."
$gitArchive = Join-Path $RuntimeDir "git.zip"
try {
    Download-File $GitUrl $gitArchive
    Extract-Zip $gitArchive (Join-Path $RuntimeDir "git")
    Write-Done "Git ready"
} catch {
    Write-Warn "Git download failed - continuing without it (not required for core functionality)"
}

# ---------------------------------------------------------------------------
# 6. Hermes source code
# ---------------------------------------------------------------------------
Write-Step "Downloading Hermes Agent source code ($HermesRef) ..."
$srcArchive = Join-Path $RuntimeDir ("source-" + $HermesRef + ".zip")
# Older pins' archives are 50-70 MB each on the stick - drop them.
Get-ChildItem $RuntimeDir -Filter "source*.zip" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $srcArchive } |
    Remove-Item -Force -ErrorAction SilentlyContinue
Download-File $SourceUrl $srcArchive
$srcTemp = Join-Path $TempDir "source"
Extract-Zip $srcArchive $srcTemp
$srcSub = Get-ChildItem $srcTemp -Directory | Select-Object -First 1
if (-not $srcSub) {
    throw "Hermes source archive did not contain a source folder"
}
$destSrc = Join-Path $SrcDir "hermes-agent"
# Lock-tolerant replace (see Copy-DirectoryContents): a plain Remove-Item + Move-Item
# aborts setup if any file in src\hermes-agent is locked on a re-run (AV / indexer /
# a running hermes). This degrades gracefully instead.
Copy-DirectoryContents $srcSub.FullName $destSrc
# Record which release is on the drive (read by launch.bat / launch.sh).
# WriteAllText = UTF-8 without BOM and no newline, so every OS compares equal.
[IO.File]::WriteAllText((Join-Path $destSrc ".portable-ref"), $HermesRef)
Write-Done "Source code ready ($HermesRef)"

# ---------------------------------------------------------------------------
# 7. Create virtual environment
# ---------------------------------------------------------------------------
Write-Step "Creating Python virtual environment ..."
$pythonExe = Join-Path $RuntimeDir "python\python.exe"
$venvDir   = Join-Path $RuntimeDir "venv"
$uvExe     = Join-Path $RuntimeDir "uv\uv.exe"

# --clear: replace any existing venv. uv 0.11.x ABORTS with "A virtual environment
# already exists ... use the --clear flag" if the target is present, so without this
# every re-run (and the launch.bat self-heal that re-runs setup when hermes.exe is
# missing) failed at this step. Matches setup-unix.sh, which rm -rf's the venv first.
& $uvExe venv $venvDir --python $pythonExe --clear
if ($LASTEXITCODE -ne 0) { throw "Failed to create venv" }
Write-Done "Virtual environment ready"

# ---------------------------------------------------------------------------
# 8. Install Hermes dependencies
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Continue"
Write-Step "Installing Hermes Python dependencies ..."
Write-Host "        This may take 3-10 minutes depending on your connection."
$venvPython = Join-Path $venvDir "Scripts\python.exe"

# Try uv first (faster), fall back to pip on unsupported filesystem (e.g. ExFAT)
# Locked install (same logic as scripts/install-deps.sh on macOS/Linux): export
# the exact package set from upstream's uv.lock and install it as-is. uv.lock
# carries upstream's override-dependencies (e.g. Pillow 13.0.0 over
# browser-harness's pillow==12.3.0 pin); a fresh resolve of [all] fails with
# ResolutionImpossible. editable_mode=compat: hermes-agent >= 0.22 builds its
# root modules in setup.py and the default editable finder maps no packages.
$reqFile = Join-Path $TempDir "hermes-requirements.txt"
Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
$installed = $false
if (Test-Path (Join-Path $destSrc "uv.lock")) {
    & $uvExe export --frozen --no-hashes --no-emit-project --no-dev --extra all --extra anthropic --extra telegram --project $destSrc -o $reqFile 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $uvExe pip install --python $venvPython --link-mode=copy --no-deps -r $reqFile
        if ($LASTEXITCODE -eq 0) {
            & $uvExe pip install --python $venvPython --link-mode=copy --no-deps -C editable_mode=compat -e $destSrc
            if ($LASTEXITCODE -eq 0) { $installed = $true }
        }
    }
}
if (-not $installed) {
    Write-Host "        Locked install unavailable - resolving with uv ..."
    & $uvExe pip install --python $venvPython --link-mode=copy -C editable_mode=compat -e "$destSrc[all,anthropic,telegram]"
    if ($LASTEXITCODE -eq 0) { $installed = $true }
}
if (-not $installed) {
    Write-Host "        uv install failed - falling back to pip ..."
    & $venvPython -m ensurepip --upgrade | Out-Null
    if (Test-Path $reqFile) {
        & $venvPython -m pip install --no-deps -r $reqFile
        if ($LASTEXITCODE -eq 0) { & $venvPython -m pip install --no-deps --config-settings editable_mode=compat -e $destSrc }
    } else {
        & $venvPython -m pip install --config-settings editable_mode=compat -e "$destSrc[all,anthropic,telegram]"
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to install Hermes dependencies" }
}
& $venvPython -c "import hermes_cli.main"
if ($LASTEXITCODE -ne 0) { throw "Hermes installed but 'import hermes_cli' fails in the venv" }
# Install stamp (same as install-deps.sh): version display + marks the tarball
# tree as externally updated, so `hermes update` does not treat it as git.
$verLine = Select-String -Path $verFile -Pattern '^hermes_agent_version:\s*(\S+)' | Select-Object -First 1
$comLine = Select-String -Path $verFile -Pattern '^hermes_agent_commit:\s*(\S+)' | Select-Object -First 1
if ($verLine -and $comLine -and ($HermesRef -ne "main")) {
    $hv = $verLine.Matches[0].Groups[1].Value
    $hc = $comLine.Matches[0].Groups[1].Value
    Push-Location $destSrc
    & $venvPython scripts\write_install_stamp.py --output install-stamp.json --update-mechanism external --commit $hc --branch $HermesRef --base-version $hv --display-version $hv --distance 0 --source build 2>&1 | Out-Null
    Pop-Location
}
Write-Done "Dependencies installed"

# ---------------------------------------------------------------------------
# 9. Install messaging dependencies (Telegram, etc.)
# ---------------------------------------------------------------------------
# Hermes [all] intentionally excludes messaging deps for size.
# The lazy-install system is supposed to auto-install on first use,
# but it can fail silently in some environments. Pre-install here
# so Telegram works out of the box.
# ---------------------------------------------------------------------------
Write-Step "Installing messaging dependencies (Telegram) ..."
$tgResult = & $uvExe pip install --python $venvPython --link-mode=copy "python-telegram-bot[webhooks]==22.8" 2>&1
if ($LASTEXITCODE -ne 0) {
    & $venvPython -m pip install "python-telegram-bot[webhooks]==22.8" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Done "python-telegram-bot ready"
    } else {
        Write-Warn "python-telegram-bot install failed - will retry on first use"
    }
} else {
    Write-Done "python-telegram-bot ready"
}

# ---------------------------------------------------------------------------
# 10. Install Playwright browsers (optional, for web tools)
# ---------------------------------------------------------------------------
Write-Step "Installing Playwright browsers (optional) ..."
$env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $RuntimeDir "playwright"
try {
    & $venvPython -m playwright install chromium 2>$null
    Write-Done "Playwright browsers ready"
} catch {
    Write-Warn "Playwright browser install failed (web tools may be limited)"
}

# ---------------------------------------------------------------------------
# 11. Mark ready
# ---------------------------------------------------------------------------
"" | Out-File (Join-Path $RuntimeDir "ready.flag") -Encoding utf8

# Cleanup temp
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Setup Complete! Launching Hermes..." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Start-Sleep -Seconds 1
