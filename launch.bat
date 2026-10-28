@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM Hermes Agent - Portable Launcher (Windows)
REM ============================================================================
REM Double-click this file to launch Hermes.
REM On first run, it downloads ~600MB of runtime files automatically.
REM All data stays in the "data\" folder - nothing touches the host computer.
REM ============================================================================

REM Resolve portable root (directory containing this script)
set "PORTABLE_ROOT=%~dp0"
set "PORTABLE_ROOT=%PORTABLE_ROOT:~0,-1%"

set "HERMES_HOME=%PORTABLE_ROOT%\data"
set "CACHE_DIR=%PORTABLE_ROOT%\.cache"
set "RUNTIME_DIR=%CACHE_DIR%\runtimes\windows-x64"
set "SRC_DIR=%PORTABLE_ROOT%\src"

REM ---------------------------------------------------------------------------
REM Launcher self-diagnostics. Every pre-menu milestone is timestamped to
REM data\logs\launcher.log, so if the window ever closes unexpectedly the log
REM shows the exact step it died on. The interactive menu stays on the console;
REM only these checkpoints are written to disk.
REM ---------------------------------------------------------------------------
if not exist "%HERMES_HOME%\logs" mkdir "%HERMES_HOME%\logs" 2>nul
set "LAUNCH_LOG=%HERMES_HOME%\logs\launcher.log"
>>"%LAUNCH_LOG%" echo(
>>"%LAUNCH_LOG%" echo ===== launch.bat start %DATE% %TIME% =====
call :ckpt "paths resolved (root=%PORTABLE_ROOT%)"

REM ---------------------------------------------------------------------------
REM Pinned Hermes Agent release (VERSION: hermes_agent_ref) - the same pin
REM setup-unix.sh / launch.sh use. If the source on the drive is older than
REM the pin, drop ready.flag so the setup below installs the pinned release.
REM ---------------------------------------------------------------------------
set "PIN_REF="
for /f "tokens=2" %%r in ('findstr /B /C:"hermes_agent_ref:" "%PORTABLE_ROOT%\VERSION" 2^>nul') do set "PIN_REF=%%r"
set "SRC_REF="
if exist "%SRC_DIR%\hermes-agent\.portable-ref" set /p SRC_REF=<"%SRC_DIR%\hermes-agent\.portable-ref"
if defined PIN_REF if not "!PIN_REF!"=="main" if not "!PIN_REF!"=="!SRC_REF!" if exist "%RUNTIME_DIR%\ready.flag" (
    echo [UPDATE] Hermes Agent on this drive: "!SRC_REF!" -^> pinned !PIN_REF!. Re-running setup ...
    call :ckpt "pin !PIN_REF! differs from source !SRC_REF! - forcing setup"
    del "%RUNTIME_DIR%\ready.flag" 2>nul
)

REM ---------------------------------------------------------------------------
REM First-run setup
REM ---------------------------------------------------------------------------
if not exist "%RUNTIME_DIR%\ready.flag" (
    echo.
    echo ============================================
    echo    Hermes Portable - First Run Setup
    echo ============================================
    echo  This will download ~600MB of runtime files
    echo  for Windows x64. Please be patient.
    echo ============================================
    echo.
    powershell -ExecutionPolicy Bypass -File "%PORTABLE_ROOT%\scripts\setup-windows.ps1" -Root "%PORTABLE_ROOT%"
    if errorlevel 1 (
        echo.
        echo [ERROR] Setup failed. Please check your internet connection and try again.
        pause
        exit /b 1
    )
)

REM ---------------------------------------------------------------------------
REM Environment isolation - keep everything inside the portable folder
REM ---------------------------------------------------------------------------
set "VIRTUAL_ENV=%RUNTIME_DIR%\venv"
set "PATH=%VIRTUAL_ENV%\Scripts;%RUNTIME_DIR%\python;%RUNTIME_DIR%\python\Scripts;%RUNTIME_DIR%\node;%RUNTIME_DIR%\git\cmd;%RUNTIME_DIR%\uv;%RUNTIME_DIR%\bin;%PATH%"
set "PYTHONNOUSERSITE=1"
set "PYTHONHOME="
set "PYTHONPATH="
set "UV_NO_CONFIG=1"
set "UV_PYTHON=%RUNTIME_DIR%\python\python.exe"
set "PLAYWRIGHT_BROWSERS_PATH=%RUNTIME_DIR%\playwright"
set "NODE_PATH=%RUNTIME_DIR%\node\node_modules"
set "NPM_CONFIG_PREFIX=%RUNTIME_DIR%\node"

REM Prevent Node from writing to host appdata
set "APPDATA=%PORTABLE_ROOT%\.cache\windows-appdata"
set "LOCALAPPDATA=%PORTABLE_ROOT%\.cache\windows-localappdata"

REM ---------------------------------------------------------------------------
REM Portable Brain (obsidian-wiki) wiring
REM The drive mounts at a different drive letter on every machine, so rewrite
REM the vault path here at launch time. Keeps the brain 100%% portable.
REM ---------------------------------------------------------------------------
set "BRAIN_VAULT=%PORTABLE_ROOT%\Brain"
set "HOME=%PORTABLE_ROOT%\.cache\windows-home"

REM Ensure the portable HOME/APPDATA/LOCALAPPDATA dirs actually exist.
REM We redirect these above so Node/Python/git never write to the host, but the
REM redirect targets must exist or git-credentials writes and pip/playwright
REM caches fail silently. (Parity with launch.sh's `mkdir -p "$HOME"`.)
if not exist "%APPDATA%" mkdir "%APPDATA%" 2>nul
if not exist "%LOCALAPPDATA%" mkdir "%LOCALAPPDATA%" 2>nul
if not exist "%HOME%" mkdir "%HOME%" 2>nul
call :ckpt "env isolation + portable dirs ready"

REM data\.env must never pin HERMES_HOME to an absolute path: the drive letter
REM or mount point differs on every machine and Hermes loads .env over the
REM environment (a Linux /run/media path broke macOS in v1.8.x). Drop
REM HERMES_HOME and point OBSIDIAN_VAULT_PATH at this drive's Brain folder.
if exist "%HERMES_HOME%\.env" powershell -NoProfile -ExecutionPolicy Bypass -Command "$e='%HERMES_HOME%\.env'; $v='%PORTABLE_ROOT%\Brain'; $l=@(Get-Content $e); $n=@($l | Where-Object { $_ -notmatch '^HERMES_HOME=' } | ForEach-Object { if ($_ -match '^OBSIDIAN_VAULT_PATH=') { 'OBSIDIAN_VAULT_PATH=' + $v } else { $_ } }); if (($n -join [char]10) -ne ($l -join [char]10)) { Set-Content -Path $e -Value $n }" 2>nul
call :ckpt "data\.env path guard done"

if exist "%BRAIN_VAULT%" (
    set "OBSIDIAN_VAULT_PATH=%BRAIN_VAULT%"
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$v='%BRAIN_VAULT%'; $h='%HERMES_HOME%'; $e=Join-Path $v '.env'; if(Test-Path $e){(Get-Content $e) -replace '^OBSIDIAN_VAULT_PATH=.*',('OBSIDIAN_VAULT_PATH='+$v) -replace '^HERMES_HOME=.*',('HERMES_HOME='+$h) | Set-Content $e}; $c=Join-Path '%HOME%' '.obsidian-wiki'; New-Item -ItemType Directory -Force -Path $c | Out-Null; Set-Content (Join-Path $c 'config') @(('OBSIDIAN_VAULT_PATH='+$v),('HERMES_HOME='+$h),'OBSIDIAN_CATEGORIES=concepts,entities,skills,references,synthesis,journal','OBSIDIAN_LINK_FORMAT=wikilink')" 2>nul
)

REM ---------------------------------------------------------------------------
REM Device identity + Git wiring + device memory (portable, per machine)
REM ---------------------------------------------------------------------------
set "DEVICE_HOST=%COMPUTERNAME%"
set "PRETTY_OS=Windows (x64)"
for /f "tokens=2 delims=[]" %%x in ('ver') do set "VERSTR=%%x"
if defined VERSTR set "PRETTY_OS=Windows %VERSTR:Version =% (x64)"
set "DEVICE_SLUG=%DEVICE_HOST%-windows-x64"

REM Git: portable identity + credential store sourced from GITHUB_TOKEN in .env
set "GITHUB_TOKEN="
if exist "%HERMES_HOME%\.env" (
    for /f "usebackq tokens=1,* delims==" %%a in (`findstr /B /C:"GITHUB_TOKEN=" "%HERMES_HOME%\.env" 2^>nul`) do set "GITHUB_TOKEN=%%b"
)
where git >nul 2>&1
if not errorlevel 1 (
    git config --global user.name "Achu Pradeep" >nul 2>&1
    git config --global user.email "achupradeep3050@gmail.com" >nul 2>&1
    git config --global init.defaultBranch main >nul 2>&1
    REM Portable drives mount on an exFAT/FAT volume that "does not record
    REM ownership", so git refuses to operate ("detected dubious ownership").
    REM --replace-all keeps exactly one entry no matter how many times we launch.
    git config --global --replace-all safe.directory "*" >nul 2>&1
    if defined GITHUB_TOKEN (
        > "%HOME%\.git-credentials" echo https://x-access-token:!GITHUB_TOKEN!@github.com
        git config --global credential.helper store >nul 2>&1
        set "GH_TOKEN=!GITHUB_TOKEN!"
    )
)

REM Record THIS device into the brain. This is done in a CALLed subroutine on
REM purpose: PRETTY_OS expands to e.g. "Windows 10.0.26200 (x64)", and an
REM unquoted "(x64)" inside a parenthesized if-block would close the block early
REM ("X was unexpected at this time"). A subroutine has no enclosing paren, so
REM the literal parentheses are harmless.
if exist "%BRAIN_VAULT%" call :record_device

REM ---------------------------------------------------------------------------
REM Launch Hermes
REM ---------------------------------------------------------------------------
call :ckpt "git + device wiring done; verifying runtime"

if not exist "%SRC_DIR%\hermes-agent" (
    call :ckpt "FATAL src\hermes-agent missing"
    echo.
    echo [ERROR] Hermes source not found at "%SRC_DIR%\hermes-agent".
    echo         Delete the .cache folder and run launch.bat again to reinstall.
    echo.
    pause
    exit /b 1
)

REM Self-heal: ready.flag can exist while the venv is incomplete (interrupted
REM install, antivirus quarantine, copy from another machine). Rather than die
REM later with a confusing "'hermes' is not recognized", repair it now.
if not exist "%VIRTUAL_ENV%\Scripts\hermes.exe" (
    call :ckpt "hermes.exe missing — re-running setup to repair"
    echo.
    echo [WARN] The Hermes runtime is incomplete ^(hermes.exe not found^).
    echo        Repairing by re-running first-run setup. This may take a few minutes ...
    echo.
    del "%RUNTIME_DIR%\ready.flag" 2>nul
    powershell -ExecutionPolicy Bypass -File "%PORTABLE_ROOT%\scripts\setup-windows.ps1" -Root "%PORTABLE_ROOT%"
    if errorlevel 1 (
        call :ckpt "FATAL runtime repair failed"
        echo.
        echo [ERROR] Repair failed. Check your internet connection and the messages above.
        pause
        exit /b 1
    )
)
call :ckpt "runtime verified (hermes.exe present)"

cd /d "%SRC_DIR%\hermes-agent"

REM Strip a leading "hermes" if the user typed "launch.bat hermes setup".
set "ARGS=%*"
if /I "%~1"=="hermes" set "ARGS=%ARGS:~7%"

REM If explicit arguments were passed, run Hermes directly (skip the menu).
REM Detect with %~1 (quote-stripped, no special chars) and run on a bare line
REM using DELAYED expansion (!ARGS!) so quotes/commas/parens inside a prompt —
REM e.g.  launch.bat -z "What is your name, friend (test)?"  — are passed
REM through to hermes verbatim instead of being re-parsed as batch syntax. The
REM old  if not "%ARGS%"=="" ( hermes %ARGS% )  form expanded %ARGS% at parse
REM time and died with "is was unexpected at this time" on any quoted prompt.
REM (Caveat: a literal "!" in the prompt is consumed by delayed expansion.)
if not "%~1"=="" (
    hermes !ARGS!
    exit /b
)

REM ---------------------------------------------------------------------------
REM ANSI Color Setup
REM ---------------------------------------------------------------------------
call :ckpt "entering interactive menu"
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "RESET=%ESC%[0m"
set "BOLD=%ESC%[1m"
set "DIM=%ESC%[2m"
set "CYAN=%ESC%[36m"
set "BRIGHT_CYAN=%ESC%[96m"
set "GREEN=%ESC%[32m"
set "BRIGHT_GREEN=%ESC%[92m"
set "YELLOW=%ESC%[33m"
set "BRIGHT_YELLOW=%ESC%[93m"
set "RED=%ESC%[31m"
set "BRIGHT_RED=%ESC%[91m"
set "WHITE=%ESC%[37m"
set "BRIGHT_WHITE=%ESC%[97m"
set "GRAY=%ESC%[90m"
set "BG_CYAN=%ESC%[46m%ESC%[30m"
set "BG_DARK=%ESC%[40m%ESC%[37m"

REM ---------------------------------------------------------------------------
REM Status Detection
REM ---------------------------------------------------------------------------
:detect_status
set "SETUP_STATUS=Not configured"
set "SETUP_ICON=[x]"
set "SETUP_COLOR=%RED%"
set "PROVIDER_NAME="
set "MODEL_NAME="
if exist "%HERMES_HOME%\.env" (
    findstr /R /C:"^[A-Z].*=" "%HERMES_HOME%\.env" >nul 2>&1
    if not errorlevel 1 (
        set "SETUP_STATUS=Configured"
        set "SETUP_ICON=[OK]"
        set "SETUP_COLOR=%BRIGHT_GREEN%"
    )
)

if exist "%HERMES_HOME%\config.yaml" (
    for /f "usebackq tokens=2 delims=: " %%a in (`findstr /R /C:"^  provider:" "%HERMES_HOME%\config.yaml"`) do (
        if not defined PROVIDER_NAME set "PROVIDER_NAME=%%a"
    )
    for /f "usebackq tokens=2 delims=: " %%a in (`findstr /R /C:"^  default:" "%HERMES_HOME%\config.yaml"`) do (
        if not defined MODEL_NAME set "MODEL_NAME=%%a"
    )
)

set "GATEWAY_STATUS=Stopped"
set "GATEWAY_ICON=[ ]"
set "GATEWAY_COLOR=%GRAY%"
set "GATEWAY_PID="
if exist "%HERMES_HOME%\gateway.pid" (
    for /f "usebackq tokens=2 delims=:," %%a in (`findstr /R /C:"\"pid\"" "%HERMES_HOME%\gateway.pid"`) do (
        set "raw=%%a"
        set "GATEWAY_PID=!raw: =!"
    )
)
if defined GATEWAY_PID (
    tasklist /FI "PID eq !GATEWAY_PID!" 2>nul | findstr /I "!GATEWAY_PID!" >nul
    if not errorlevel 1 (
        set "GATEWAY_STATUS=Running (PID !GATEWAY_PID!)"
        set "GATEWAY_ICON=[OK]"
        set "GATEWAY_COLOR=%BRIGHT_GREEN%"
    ) else (
        set "GATEWAY_STATUS=Stopped (stale lock)"
        set "GATEWAY_ICON=[!]"
        set "GATEWAY_COLOR=%YELLOW%"
    )
)

set "HERMES_VERSION=unknown"
if exist "%SRC_DIR%\hermes-agent\hermes_cli\__init__.py" (
    for /f "usebackq tokens=3" %%a in (`findstr /R /C:"__version__" "%SRC_DIR%\hermes-agent\hermes_cli\__init__.py"`) do (
        set "rawver=%%a"
        set "HERMES_VERSION=!rawver:"=!"
    )
)

REM Brain (Obsidian) + connection status
set "BRAIN_PAGES=0"
if exist "%BRAIN_VAULT%" (
    for /f %%c in ('dir /b /s "%BRAIN_VAULT%\*.md" 2^>nul ^| find /c /v ""') do set "BRAIN_PAGES=%%c"
)
set "TELEGRAM_STATUS=Not set"
findstr /B /C:"TELEGRAM_BOT_TOKEN=" "%HERMES_HOME%\.env" >nul 2>&1
if not errorlevel 1 set "TELEGRAM_STATUS=Configured"
set "GIT_STATUS=Not set"
findstr /B /C:"GITHUB_TOKEN=" "%HERMES_HOME%\.env" >nul 2>&1
if not errorlevel 1 set "GIT_STATUS=Configured"

REM ---------------------------------------------------------------------------
REM Main Menu
REM ---------------------------------------------------------------------------
:show_menu
echo.
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo %BOLD%%BRIGHT_WHITE%                    HERMES PORTABLE LAUNCHER%RESET%
echo %DIM%%GRAY%                         AI Agent for Everyone%RESET%
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.
echo  %DIM%Device%RESET%   %WHITE%!DEVICE_HOST!%RESET% %GRAY%-%RESET% %CYAN%!PRETTY_OS!%RESET%
echo  %DIM%Setup%RESET%    !SETUP_COLOR!!SETUP_ICON!%RESET% %WHITE%!SETUP_STATUS!%RESET%
if defined PROVIDER_NAME echo  %DIM%Provider%RESET% %CYAN%!PROVIDER_NAME!%RESET%
if defined MODEL_NAME echo  %DIM%Model%RESET%    %WHITE%!MODEL_NAME!%RESET%
echo  %DIM%Brain%RESET%    %BRIGHT_GREEN%[OK]%RESET% %WHITE%!BRAIN_PAGES! pages%RESET% %GRAY%(Obsidian)%RESET%
echo  %DIM%Gateway%RESET%  !GATEWAY_COLOR!!GATEWAY_ICON!%RESET% %WHITE%!GATEWAY_STATUS!%RESET%
echo  %DIM%Telegram%RESET% %WHITE%!TELEGRAM_STATUS!%RESET%   %DIM%Git%RESET% %WHITE%!GIT_STATUS!%RESET%
echo  %DIM%Version%RESET%  %GRAY%v!HERMES_VERSION!%RESET%
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.
echo  %BRIGHT_YELLOW%[1]%RESET%  %WHITE%Start Hermes Chat%RESET%
echo  %BRIGHT_YELLOW%[2]%RESET%  %WHITE%Setup / Reconfigure Hermes%RESET%
echo  %BRIGHT_YELLOW%[M]%RESET%  %WHITE%Switch Model / Provider%RESET%  %GRAY%fast%RESET%
if "!GATEWAY_STATUS!"=="Running (PID !GATEWAY_PID!)" (
    echo  %BRIGHT_YELLOW%[3]%RESET%  %WHITE%Stop Gateway%RESET%  %RED%[live]%RESET%
) else (
    echo  %BRIGHT_YELLOW%[3]%RESET%  %WHITE%Start Gateway%RESET%
)
echo  %BRIGHT_YELLOW%[4]%RESET%  %WHITE%Advanced Options%RESET%  %GRAY%--^>%RESET%
echo  %BRIGHT_YELLOW%[5]%RESET%  %GRAY%Exit%RESET%
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.

echo %BRIGHT_CYAN%Select option:%RESET% & choice /C 12345M /N
if errorlevel 6 goto :menu_model
if errorlevel 5 goto :menu_exit
if errorlevel 4 goto :show_advanced
if errorlevel 3 goto :menu_gateway
if errorlevel 2 goto :menu_setup
if errorlevel 1 goto :menu_chat
goto :show_menu

REM ---------------------------------------------------------------------------
REM Menu Actions
REM ---------------------------------------------------------------------------
:menu_chat
echo.
hermes
goto :show_menu

:menu_setup
echo.
hermes setup
goto :detect_status

:menu_model
cls
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo %BOLD%%BRIGHT_WHITE%                  Switch Model / Provider%RESET%
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.
echo  %BRIGHT_YELLOW%[1]%RESET%  NVIDIA - DeepSeek V4  %BRIGHT_GREEN%free credits%RESET% (cloud, NIM)
echo  %BRIGHT_YELLOW%[2]%RESET%  Kimi for Coding   (cloud, API key)
echo  %BRIGHT_YELLOW%[3]%RESET%  Ollama            (local)
echo  %BRIGHT_YELLOW%[4]%RESET%  LM Studio         (local)
echo  %BRIGHT_YELLOW%[5]%RESET%  Google Gemini     %BRIGHT_GREEN%login with Google%RESET% (OAuth, no API key)
echo  %BRIGHT_YELLOW%[6]%RESET%  Google Gemini     (cloud, API key)
echo  %BRIGHT_YELLOW%[7]%RESET%  OpenRouter        (cloud)
echo  %BRIGHT_YELLOW%[8]%RESET%  Anthropic Claude  (cloud)
echo  %BRIGHT_YELLOW%[9]%RESET%  Custom endpoint
echo  %BRIGHT_YELLOW%[10]%RESET% Full picker (hermes model)
echo  %BRIGHT_YELLOW%[11]%RESET% Back
echo.
REM set /p (not choice) so the two-digit "10"/"11" can be entered.
set "MC="
set /p "MC=Select model: "
if "!MC!"=="1" goto :mdl_nvidia
if "!MC!"=="2" goto :mdl_kimi
if "!MC!"=="3" goto :mdl_ollama
if "!MC!"=="4" goto :mdl_lmstudio
if "!MC!"=="5" goto :mdl_gemini_oauth
if "!MC!"=="6" goto :mdl_gemini
if "!MC!"=="7" goto :mdl_openrouter
if "!MC!"=="8" goto :mdl_anthropic
if "!MC!"=="9" goto :mdl_custom
if "!MC!"=="10" ( hermes model & goto :model_done )
if "!MC!"=="11" goto :detect_status
goto :menu_model

:mdl_nvidia
REM NVIDIA NIM - free credits at build.nvidia.com. The native 'nvidia' provider
REM reads NVIDIA_API_KEY and has the NIM base_url built in. DeepSeek V4: 'flash'
REM is the verified default (fast first token). 'deepseek-ai/deepseek-v4-pro' is
REM stronger but runs in full thinking mode and stalls past Hermes' 180s
REM stream-stale limit with large context - typeable but not recommended.
REM Mirrors launch.sh menu_model option [1].
set "M=deepseek-ai/deepseek-v4-flash"
set /p "M=NVIDIA model [deepseek-ai/deepseek-v4-flash]: "
findstr /B /C:"NVIDIA_API_KEY=" "%HERMES_HOME%\.env" 2>nul | findstr /R "=..*" >nul 2>&1
if errorlevel 1 (
    set "K="
    set /p "K=NVIDIA_API_KEY (free at build.nvidia.com): "
    python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider nvidia --model "!M!" --base-url "" --set-env NVIDIA_API_KEY=!K!
) else (
    python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider nvidia --model "!M!" --base-url ""
)
goto :model_done

:mdl_kimi
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider kimi-coding --model kimi-for-coding --base-url ""
goto :model_done

:mdl_ollama
set "M=llama3.1"
set /p "M=Ollama model [llama3.1]: "
set "U=http://localhost:11434/v1"
set /p "U=Ollama URL [http://localhost:11434/v1]: "
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider custom --model "!M!" --base-url "!U!" --set-env OPENAI_API_KEY=ollama
goto :model_done

:mdl_lmstudio
set "M="
set /p "M=LM Studio model name: "
set "U=http://127.0.0.1:1234/v1"
set /p "U=LM Studio URL [http://127.0.0.1:1234/v1]: "
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider lmstudio --model "!M!" --base-url "!U!"
goto :model_done

:mdl_gemini_oauth
REM Google Gemini via "Login with Google" (OAuth) — provider google-gemini-cli,
REM no API key. Mirrors launch.sh menu_model_gemini_oauth so Windows + macOS
REM behave identically. Browser PKCE sign-in; creds -> data/auth/google_oauth.json
REM (on the USB, so the login travels with the drive).
echo.
echo %BRIGHT_YELLOW%Google Gemini - Login with Google (OAuth, no API key)%RESET%
echo %GRAY%A browser window will open so you can sign in to Google. The login is%RESET%
echo %GRAY%stored on this USB, so it works on any machine you plug into.%RESET%
echo %GRAY%(Already logged in? Just press Enter at the prompts to keep it.)%RESET%
echo.
hermes auth add google-gemini-cli
if errorlevel 1 (
    echo.
    echo %YELLOW%Google sign-in did not complete - model left unchanged.%RESET%
    goto :model_done
)
echo.
set "M=gemini-3-flash-preview"
set /p "M=Gemini model [gemini-3-flash-preview]: "
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider google-gemini-cli --model "!M!" --base-url ""
echo %BRIGHT_GREEN%Switched to Google Gemini (login) - !M!%RESET%
goto :model_done

:mdl_gemini
set "M=gemini-2.5-flash"
set /p "M=Gemini model [gemini-2.5-flash]: "
set "K="
set /p "K=GEMINI_API_KEY: "
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider gemini --model "!M!" --base-url "" --set-env GEMINI_API_KEY=!K!
goto :model_done

:mdl_openrouter
set "M=anthropic/claude-sonnet-4"
set /p "M=OpenRouter model [anthropic/claude-sonnet-4]: "
set "K="
set /p "K=OPENROUTER_API_KEY: "
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider openrouter --model "!M!" --base-url "" --set-env OPENROUTER_API_KEY=!K!
goto :model_done

:mdl_anthropic
set "M=claude-sonnet-4-6"
set /p "M=Claude model [claude-sonnet-4-6]: "
set "K="
set /p "K=ANTHROPIC_API_KEY: "
python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider anthropic --model "!M!" --base-url "" --set-env ANTHROPIC_API_KEY=!K!
goto :model_done

:mdl_custom
set "U="
set /p "U=Base URL (OpenAI-compatible): "
set "M="
set /p "M=Model name: "
set "K="
set /p "K=API key (blank if none): "
if "!K!"=="" (
    python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider custom --model "!M!" --base-url "!U!"
) else (
    python "%PORTABLE_ROOT%\scripts\switch-model.py" --config "%HERMES_HOME%\config.yaml" --env "%HERMES_HOME%\.env" --provider custom --model "!M!" --base-url "!U!" --set-env OPENAI_API_KEY=!K!
)
goto :model_done

:model_done
echo.
echo %BRIGHT_GREEN%Model updated.%RESET%
pause
goto :detect_status

:menu_gateway
if "!GATEWAY_STATUS!"=="Running (PID !GATEWAY_PID!)" (
    hermes gateway stop
    echo.
    echo %BRIGHT_GREEN%Gateway stopped.%RESET%
) else (
    echo.
    echo %CYAN%Starting gateway in a detached window ...%RESET%
    if not exist "%HERMES_HOME%\logs" mkdir "%HERMES_HOME%\logs"
    REM NOTE: redirect the console to gateway.console.log, NOT gateway.log. Hermes
REM opens data\logs\gateway.log itself via a rotating handler; on Windows a
REM shell ">" redirect to that same path takes an exclusive lock and Hermes
REM dies with "PermissionError: [Errno 13] ... gateway.log". A separate console
REM file avoids the clash. (On macOS launch.sh can share the handle, so this is
REM a Windows-only divergence.)
start "Hermes Gateway" /min cmd /c hermes gateway run ^> "%HERMES_HOME%\logs\gateway.console.log" 2^>^&1
    timeout /t 4 /nobreak >nul
    call :notify_tg
)
pause
goto :detect_status

:notify_tg
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{$e=Get-Content '%HERMES_HOME%\.env' -ErrorAction Stop; $tok=(($e|Select-String '^TELEGRAM_BOT_TOKEN=')[0] -split '=',2)[1].Trim(); $chat=((($e|Select-String '^TELEGRAM_ALLOWED_USERS=')[0] -split '=',2)[1] -split ',')[0].Trim(); if($tok -and $chat){Invoke-RestMethod -Method Post -Uri ('https://api.telegram.org/bot'+$tok+'/sendMessage') -Body @{chat_id=$chat;text='Hermes gateway is ONLINE. Send me a message on @Hermes3050bot!'}|Out-Null}}catch{}" >nul 2>&1
exit /b

:menu_exit
echo.
echo.
echo %GRAY%Goodbye!%RESET%
echo.
exit /b

REM ---------------------------------------------------------------------------
REM Advanced Menu
REM ---------------------------------------------------------------------------
:show_advanced
echo.
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo %BOLD%%BRIGHT_WHITE%                       Advanced Options%RESET%
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.
echo  %BRIGHT_YELLOW%[1]%RESET%  %WHITE%Run Doctor%RESET%            %GRAY%- check for issues%RESET%
echo  %BRIGHT_YELLOW%[2]%RESET%  %WHITE%View Logs%RESET%             %GRAY%- last 20 lines%RESET%
echo  %BRIGHT_YELLOW%[3]%RESET%  %WHITE%Edit Config%RESET%           %GRAY%- open in editor%RESET%
echo  %BRIGHT_YELLOW%[4]%RESET%  %WHITE%Restart Gateway%RESET%       %GRAY%- stop + start%RESET%
echo  %BRIGHT_YELLOW%[5]%RESET%  %WHITE%Update Hermes%RESET%         %GRAY%- fetch latest%RESET%
echo  %BRIGHT_YELLOW%[6]%RESET%  %GRAY%Back to Main Menu%RESET%
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.

echo %BRIGHT_CYAN%Select option:%RESET% & choice /C 123456 /N
if errorlevel 6 goto :show_menu
if errorlevel 5 goto :adv_update
if errorlevel 4 goto :adv_restart
if errorlevel 3 goto :adv_config
if errorlevel 2 goto :adv_logs
if errorlevel 1 goto :adv_doctor
goto :show_advanced

:adv_doctor
echo.
hermes doctor
pause
goto :show_advanced

:adv_logs
echo.
if exist "%HERMES_HOME%\logs\gateway.log" (
    echo %CYAN%=== Gateway Log ^(last 20 lines^) ===%RESET%
    powershell -Command "Get-Content '%HERMES_HOME%\logs\gateway.log' -Tail 20"
) else (
    echo %YELLOW%No logs found.%RESET%
)
echo.
pause
goto :show_advanced

:adv_config
echo.
hermes config edit
goto :show_advanced

:adv_restart
echo %CYAN%Restarting gateway ...%RESET%
hermes gateway stop >nul 2>&1
if not exist "%HERMES_HOME%\logs" mkdir "%HERMES_HOME%\logs"
REM NOTE: redirect the console to gateway.console.log, NOT gateway.log. Hermes
REM opens data\logs\gateway.log itself via a rotating handler; on Windows a
REM shell ">" redirect to that same path takes an exclusive lock and Hermes
REM dies with "PermissionError: [Errno 13] ... gateway.log". A separate console
REM file avoids the clash. (On macOS launch.sh can share the handle, so this is
REM a Windows-only divergence.)
start "Hermes Gateway" /min cmd /c hermes gateway run ^> "%HERMES_HOME%\logs\gateway.console.log" 2^>^&1
timeout /t 4 /nobreak >nul
call :notify_tg
echo.
echo %BRIGHT_GREEN%Gateway restarted.%RESET%
pause
goto :detect_status

:adv_update
echo.
hermes update
pause
goto :show_advanced

REM ---------------------------------------------------------------------------
REM :ckpt  — append a timestamped milestone to the launcher log.
REM Called throughout the pre-menu phase so a silent crash is traceable to the
REM last line that succeeded. Never fails the script (errors are swallowed).
REM ---------------------------------------------------------------------------
:ckpt
>>"%LAUNCH_LOG%" echo [%TIME%] %~1
exit /b 0

REM ---------------------------------------------------------------------------
REM :record_device — write/refresh this machine's device note in the brain.
REM Lives in a subroutine (not an inline if-block) so PRETTY_OS's "(x64)" and
REM the PowerShell parentheses can never break cmd's block parser.
REM ---------------------------------------------------------------------------
:record_device
powershell -NoProfile -ExecutionPolicy Bypass -File "%PORTABLE_ROOT%\scripts\record-device.ps1" -Root "%PORTABLE_ROOT%" -DeviceSlug "%DEVICE_SLUG%" -DeviceHost "%DEVICE_HOST%" -PrettyOS "%PRETTY_OS%" 2>nul
echo Running on %PRETTY_OS% as %DEVICE_HOST% - device remembered in the brain.
exit /b 0
