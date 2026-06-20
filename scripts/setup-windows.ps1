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
$TempDir    = Join-Path $Root ".tmp"


New-Item -ItemType Directory -Force -Path $RuntimeDir, $SrcDir, $BinDir, $TempDir | Out-Null

# Clean up macOS metadata junk files (._*) from exFAT drives to prevent pip/uv errors
Get-ChildItem -Path $Root -Filter "._*" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Download URLs (pinned for reliability)
# ---------------------------------------------------------------------------
$PythonUrl  = "https://github.com/astral-sh/python-build-standalone/releases/download/20260602/cpython-3.11.15+20260602-x86_64-pc-windows-msvc-install_only.tar.gz"
$NodeUrl    = "https://nodejs.org/dist/v22.22.3/node-v22.22.3-win-x64.zip"
$UvUrl      = "https://github.com/astral-sh/uv/releases/download/0.11.19/uv-x86_64-pc-windows-msvc.zip"
$RgUrl      = "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-x86_64-pc-windows-msvc.zip"
$GitUrl     = "https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/MinGit-2.54.0-64-bit.zip"
$SourceUrl  = "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.zip"

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
        $curlArgs = @("-L", "-f", "--ssl-no-revoke", "--retry", "3", "--retry-delay", "2", "--connect-timeout", "30", "--max-time", "900", "-o", $OutFile, $Url)
        & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warn ("curl.exe failed with exit code " + $LASTEXITCODE + " - falling back to PowerShell download ...")
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            } catch {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
            }
            catch {
                if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
                throw "Failed to download " + $name + ": " + $_
            }
        }
    } else {
        $ProgressPreference = 'Continue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 900
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
    # Use Windows built-in tar to avoid Git Bash tar path issues
    $winTar = "C:\Windows\System32\tar.exe"
    if (Test-Path $winTar) {
        & $winTar -xzf "$Archive" -C "$Destination" --strip-components=1
    } else {
        & tar.exe -xzf "$Archive" -C "$Destination" --strip-components=1
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
        try {
            Expand-Archive -Path $Archive -DestinationPath $Destination -Force
            $extracted = $true
        } catch {
            if (Test-Path $Destination) {
                Remove-Item $Destination -Recurse -Force
                New-Item -ItemType Directory -Force -Path $Destination | Out-Null
            }
        }

        $winTar = "C:\Windows\System32\tar.exe"
        if ((-not $extracted) -and (Test-Path $winTar)) {
            & $winTar -xf "$Archive" -C "$Destination" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $extracted = $true
            }
        } elseif ((-not $extracted) -and (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
            & tar.exe -xf "$Archive" -C "$Destination" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $extracted = $true
            }
        }

        if (-not $extracted) {
            if (Test-Path $Destination) {
                Remove-Item $Destination -Recurse -Force
                New-Item -ItemType Directory -Force -Path $Destination | Out-Null
            }
            throw "no available zip extractor succeeded"
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
    $coreFiles = @("python\python.exe", "uv\uv.exe", "venv\Scripts\python.exe")
    $missing = $coreFiles | Where-Object { -not (Test-Path (Join-Path $RuntimeDir $_)) }
    if ($missing) {
        Write-Warn "ready.flag exists but core files are missing - restarting setup ..."
        Remove-Item $readyFlag -Force
    }
}

# ---------------------------------------------------------------------------
# 1. Portable Python
# ---------------------------------------------------------------------------
Write-Step "Installing portable Python 3.11 ..."
$pyArchive = Join-Path $RuntimeDir "python.tar.gz"
Download-File $PythonUrl $pyArchive
Extract-TarGz $pyArchive (Join-Path $RuntimeDir "python")
Write-Done "Python ready"

# ---------------------------------------------------------------------------
# 2. Node.js
# ---------------------------------------------------------------------------
Write-Step "Installing Node.js 22 LTS ..."
$nodeArchive = Join-Path $RuntimeDir "node.zip"
Download-File $NodeUrl $nodeArchive
$nodeTemp = Join-Path $TempDir "node"
Extract-Zip $nodeArchive $nodeTemp
Move-SubfolderContents $nodeTemp (Join-Path $RuntimeDir "node")
& (Join-Path $RuntimeDir "node\node.exe") --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Node.js verification failed" }
& (Join-Path $RuntimeDir "node\npm.cmd") --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "npm verification failed" }
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
Write-Step "Downloading Hermes Agent source code ..."
$srcArchive = Join-Path $RuntimeDir "source.zip"
Download-File $SourceUrl $srcArchive
$srcTemp = Join-Path $TempDir "source"
Extract-Zip $srcArchive $srcTemp
$srcSub = Get-ChildItem $srcTemp -Directory | Select-Object -First 1
if (-not $srcSub) {
    throw "Hermes source archive did not contain a source folder"
}
$destSrc = Join-Path $SrcDir "hermes-agent"
Copy-DirectoryContents $srcSub.FullName $destSrc
Write-Done "Source code ready"

# ---------------------------------------------------------------------------
# 7. Create virtual environment
# ---------------------------------------------------------------------------
Write-Step "Creating Python virtual environment ..."
$pythonExe = Join-Path $RuntimeDir "python\python.exe"
$venvDir   = Join-Path $RuntimeDir "venv"
$uvExe     = Join-Path $RuntimeDir "uv\uv.exe"

& $uvExe venv $venvDir --python $pythonExe
if ($LASTEXITCODE -ne 0) {
    Write-Warn "uv venv failed - falling back to Python venv with copied files ..."
    Remove-Item $venvDir -Recurse -Force -ErrorAction SilentlyContinue
    & $pythonExe -m venv $venvDir --copies
    if ($LASTEXITCODE -ne 0) { throw "Failed to create venv" }
}
& (Join-Path $venvDir "Scripts\python.exe") --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Virtual environment verification failed" }
Write-Done "Virtual environment ready"

# ---------------------------------------------------------------------------
# 8. Install Hermes dependencies
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Continue"
Write-Step "Installing Hermes Python dependencies ..."
Write-Host "        This may take 3-10 minutes depending on your connection."
$venvPython = Join-Path $venvDir "Scripts\python.exe"

# Try uv first (faster), fall back to pip on unsupported filesystem (e.g. ExFAT)
& $uvExe pip install --python $venvPython --link-mode=copy -e "$destSrc[all]"
if ($LASTEXITCODE -ne 0) {
    Write-Host "        uv install failed - falling back to pip ..."
    & $venvPython -m ensurepip --upgrade | Out-Null
    & $venvPython -m pip install -e "$destSrc[all]"
    if ($LASTEXITCODE -ne 0) { throw "Failed to install Hermes dependencies" }
}
Write-Done "Dependencies installed"

# ---------------------------------------------------------------------------
# 9. Install provider dependencies
# ---------------------------------------------------------------------------
Write-Step "Installing provider dependencies ..."
& $uvExe pip install --python $venvPython --link-mode=copy "anthropic>=0.39.0"
if ($LASTEXITCODE -ne 0) {
    & $venvPython -m pip install "anthropic>=0.39.0" >$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Done "Provider dependencies ready"
    } else {
        Write-Warn "Anthropic provider install failed - will retry on first use"
    }
} else {
    Write-Done "Provider dependencies ready"
}

# ---------------------------------------------------------------------------
# 10. Install messaging dependencies (Telegram, etc.)
# ---------------------------------------------------------------------------
# Hermes [all] intentionally excludes messaging deps for size.
# The lazy-install system is supposed to auto-install on first use,
# but it can fail silently in some environments. Pre-install here
# so Telegram works out of the box.
# ---------------------------------------------------------------------------
Write-Step "Installing messaging dependencies (Telegram) ..."
& $uvExe pip install --python $venvPython --link-mode=copy "python-telegram-bot[webhooks]==22.6"
if ($LASTEXITCODE -ne 0) {
    & $venvPython -m pip install "python-telegram-bot[webhooks]==22.6" >$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Done "python-telegram-bot ready"
    } else {
        Write-Warn "python-telegram-bot install failed - will retry on first use"
    }
} else {
    Write-Done "python-telegram-bot ready"
}

# ---------------------------------------------------------------------------
# 11. Install Playwright browsers (optional, for web tools)
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
# 12. Mark ready
# ---------------------------------------------------------------------------
"" | Out-File (Join-Path $RuntimeDir "ready.flag") -Encoding utf8

# Cleanup temp
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "   Setup Complete! Launching Hermes..." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Start-Sleep -Seconds 1
