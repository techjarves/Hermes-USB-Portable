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
set "PATH=%VIRTUAL_ENV%\Scripts;%RUNTIME_DIR%\python;%RUNTIME_DIR%\python\Scripts;%RUNTIME_DIR%\node;%RUNTIME_DIR%\uv;%RUNTIME_DIR%\bin;%PATH%"

REM Make portable MinGit available (hermes update / git-based tools) if it was installed
if exist "%RUNTIME_DIR%\git\cmd\git.exe" (
    set "PATH=%RUNTIME_DIR%\git\cmd;%RUNTIME_DIR%\git\mingw64\bin;%PATH%"
    set "GIT_EXEC_PATH=%RUNTIME_DIR%\git\mingw64\libexec\git-core"
    set "GIT_CONFIG_NOSYSTEM=1"
)
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
REM Update pyvenv.cfg with the current absolute path to ensure portability
REM ---------------------------------------------------------------------------
if exist "%VIRTUAL_ENV%\pyvenv.cfg" (
    for /f "tokens=2" %%v in ('"%RUNTIME_DIR%\python\python.exe" --version 2^>nul') do set "PYTHON_VERSION=%%v"
    if not defined PYTHON_VERSION set "PYTHON_VERSION=3.11.15"
    (
    echo home = %RUNTIME_DIR%\python
    echo include-system-site-packages = false
    echo version = !PYTHON_VERSION!
    ) > "%VIRTUAL_ENV%\pyvenv.cfg"
)

REM ---------------------------------------------------------------------------
REM Launch Hermes
REM ---------------------------------------------------------------------------
if not exist "%SRC_DIR%\hermes-agent" (
    echo [ERROR] Hermes source not found. Please delete .cache and try again.
    pause
    exit /b 1
)

cd /d "%SRC_DIR%\hermes-agent"

REM Strip "hermes" from the start of arguments if user typed "launch.bat hermes setup"
set "ARGS=%*"
if /I "%~1"=="hermes" (
    set "ARGS=%ARGS:~7%"
)

if /I "%~1"=="start-server" (
    for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
    set "RESET=!ESC![0m"
    set "CYAN=!ESC![36m"
    set "YELLOW=!ESC![33m"
    set "RED=!ESC![31m"
    set "BRIGHT_GREEN=!ESC![92m"
    set "GREEN=!ESC![32m"
    set "PROVIDER_NAME=custom"
    call :ensure_llama_server
    exit /b
)

if /I "%~1"=="stop-server" (
    for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
    set "RESET=!ESC![0m"
    set "CYAN=!ESC![36m"
    set "PROVIDER_NAME=custom"
    call :stop_llama_server
    exit /b
)

REM If explicit arguments were passed, run Hermes directly (skip menu)
if not "%ARGS%"=="" (
    python -c "from hermes_cli.main import main; main()" %ARGS%
    exit /b
)

REM ---------------------------------------------------------------------------
REM ANSI Color Setup
REM ---------------------------------------------------------------------------
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
        if not defined PROVIDER_NAME (
            set "raw_prov=%%a"
            set "PROVIDER_NAME=!raw_prov:"=!"
        )
    )
    for /f "usebackq tokens=2 delims=: " %%a in (`findstr /R /C:"^  default:" "%HERMES_HOME%\config.yaml"`) do (
        if not defined MODEL_NAME (
            set "raw_mod=%%a"
            set "MODEL_NAME=!raw_mod:"=!"
        )
    )
)

set "LLAMA_STATUS=Stopped"
set "LLAMA_ICON=[ ]"
set "LLAMA_COLOR=%GRAY%"
set "LLAMA_PID="
if exist "%HERMES_HOME%\llama-server.pid" (
    set /p LLAMA_PID=<"%HERMES_HOME%\llama-server.pid"
)
if defined LLAMA_PID (
    tasklist /FI "PID eq !LLAMA_PID!" 2>nul | findstr /I "!LLAMA_PID!" >nul
    if not errorlevel 1 (
        set "LLAMA_STATUS=Running (PID !LLAMA_PID!)"
        set "LLAMA_ICON=[OK]"
        set "LLAMA_COLOR=%BRIGHT_GREEN%"
    ) else (
        set "LLAMA_STATUS=Stopped"
        del "%HERMES_HOME%\llama-server.pid" >nul 2>&1
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
echo  %DIM%Setup%RESET%    !SETUP_COLOR!!SETUP_ICON!%RESET% %WHITE%!SETUP_STATUS!%RESET%
if defined PROVIDER_NAME echo  %DIM%Provider%RESET% %CYAN%!PROVIDER_NAME!%RESET%
if defined MODEL_NAME echo  %DIM%Model%RESET%    %WHITE%!MODEL_NAME!%RESET%
echo  %DIM%Gateway%RESET%  !GATEWAY_COLOR!!GATEWAY_ICON!%RESET% %WHITE%!GATEWAY_STATUS!%RESET%
if "!PROVIDER_NAME!"=="custom" echo  %DIM%Llama Srv%RESET% !LLAMA_COLOR!!LLAMA_ICON!%RESET% %WHITE%!LLAMA_STATUS!%RESET%
echo  %DIM%Version%RESET%  %GRAY%v!HERMES_VERSION!%RESET%
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.
echo  %BRIGHT_YELLOW%[1]%RESET%  %WHITE%Start Hermes Chat%RESET%
echo  %BRIGHT_YELLOW%[D]%RESET%  %WHITE%Start Hermes Desktop%RESET%
echo  %BRIGHT_YELLOW%[2]%RESET%  %WHITE%Setup / Reconfigure Hermes%RESET%
if "!GATEWAY_STATUS!"=="Running (PID !GATEWAY_PID!)" (
    echo  %BRIGHT_YELLOW%[3]%RESET%  %WHITE%Stop Gateway%RESET%  %RED%[live]%RESET%
) else (
    echo  %BRIGHT_YELLOW%[3]%RESET%  %WHITE%Start Gateway%RESET%
)
echo  %BRIGHT_YELLOW%[4]%RESET%  %WHITE%Advanced Options%RESET%  %GRAY%--^>%RESET%
echo  %BRIGHT_YELLOW%[L]%RESET%  %WHITE%Setup Local LLM (llama.cpp)%RESET%
echo  %BRIGHT_YELLOW%[5]%RESET%  %GRAY%Exit%RESET%
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.

echo %BRIGHT_CYAN%Select option:%RESET% & choice /C 12345LD /N
if errorlevel 7 goto :menu_desktop
if errorlevel 6 goto :menu_local_setup
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
call :ensure_llama_server
if errorlevel 1 goto :show_menu
python -c "from hermes_cli.main import main; main()"
call :stop_llama_server
goto :show_menu

:menu_setup
echo.
python -c "from hermes_cli.main import main; main()" setup
goto :detect_status

:menu_gateway
if "!GATEWAY_STATUS!"=="Running (PID !GATEWAY_PID!)" (
    python -c "from hermes_cli.main import main; main()" gateway stop
    call :stop_llama_server
    echo.
    echo %BRIGHT_GREEN%Gateway stopped.%RESET%
) else (
    echo.
    call :ensure_llama_server
    if errorlevel 1 goto :show_menu
    echo %CYAN%Starting gateway in background ...%RESET%
    start "" python -c "from hermes_cli.main import main; main()" gateway
    timeout /t 2 /nobreak >nul
)
pause
goto :detect_status

:menu_desktop
echo.
call :ensure_llama_server
if errorlevel 1 goto :show_menu
echo %CYAN%Starting Hermes Desktop app ...%RESET%
python -c "from hermes_cli.main import main; main()" desktop
call :stop_llama_server
goto :detect_status

:menu_local_setup
echo.
python "%PORTABLE_ROOT%\scripts\local_setup_server.py"
goto :detect_status

:menu_exit
echo.
echo.
if not "!GATEWAY_STATUS!"=="Running (PID !GATEWAY_PID!)" (
    call :stop_llama_server
)
echo %GRAY%Goodbye!%RESET%
echo.
exit /b

:ensure_llama_server
if /I "!PROVIDER_NAME!"=="custom" (
    if exist "%HERMES_HOME%\config.yaml" (
        powershell -Command "Get-Content '%HERMES_HOME%\config.yaml' | ForEach-Object { $_ -replace '127.0.0.1:11434/v1', '127.0.0.1:39600/v1' -replace 'localhost:11434/v1', '127.0.0.1:39600/v1' } | Set-Content '%HERMES_HOME%\config.yaml.tmp'; Move-Item -Force '%HERMES_HOME%\config.yaml.tmp' '%HERMES_HOME%\config.yaml'"
    )
    if exist "%HERMES_HOME%\llama-server.pid" (
        set /p LLAMA_PID=<"%HERMES_HOME%\llama-server.pid"
    )
    set "RUNNING="
    if defined LLAMA_PID (
        tasklist /FI "PID eq !LLAMA_PID!" 2>nul | findstr /I "!LLAMA_PID!" >nul
        if not errorlevel 1 set "RUNNING=1"
    )
    if not defined RUNNING (
        echo %CYAN%Starting local llama-server in background ...%RESET%
        
        set "MODEL_FILE="
        for /f "usebackq tokens=2 delims=: " %%a in (`findstr /R /C:"^  default:" "%HERMES_HOME%\config.yaml"`) do (
            set "raw_model=%%a"
            set "MODEL_FILE=!raw_model:custom/=!"
            set "MODEL_FILE=!MODEL_FILE:"=!"
        )
        
        set "MODEL_PATH="
        if defined MODEL_FILE (
            if exist "%HERMES_HOME%\models\!MODEL_FILE!" (
                set "MODEL_PATH=%HERMES_HOME%\models\!MODEL_FILE!"
            ) else (
                for /r "%HERMES_HOME%\models" %%f in (*.gguf) do (
                    if "%%~nxf"=="!MODEL_FILE!" (
                        set "MODEL_PATH=%%f"
                    )
                )
            )
        )
        
        if not defined MODEL_PATH (
            echo %YELLOW%Warning: Configured model "!MODEL_FILE!" not found. Fallback to first GGUF found.%RESET%
            for /r "%HERMES_HOME%\models" %%f in (*.gguf) do (
                if not defined MODEL_PATH set "MODEL_PATH=%%f"
            )
        )
        
        if not defined MODEL_PATH (
            echo %RED%Error: No GGUF model file configured or found. Run [L] to configure.%RESET%
            pause
            exit /b 1
        )
        
        set "SERVER_EXE=%CACHE_DIR%\runtimes\llama-server\llama-server.exe"
        if not exist "!SERVER_EXE!" (
            echo %RED%Error: llama-server executable not found at !SERVER_EXE!. Run [L] to setup.%RESET%
            pause
            exit /b 1
        )
        
        set "GPU_ARGS="
        if exist "C:\Windows\System32\nvcuda.dll" (
            echo %BRIGHT_GREEN%NVIDIA GPU detected. Enabling GPU acceleration ^(offloading layers to VRAM^).%RESET%
            set "GPU_ARGS=-ngl 99"
        )
        
        set "CTX_LEN=32768"
        if exist "%HERMES_HOME%\config.yaml" (
            for /f "usebackq tokens=2 delims=: " %%a in (`findstr /R /C:"^  context_length:" "%HERMES_HOME%\config.yaml"`) do (
                set "raw_ctx=%%a"
                set "CTX_LEN=!raw_ctx:"=!"
            )
        )
        
        for /f "usebackq" %%p in (`powershell -Command "Start-Process -FilePath '!SERVER_EXE!' -ArgumentList '-m \"!MODEL_PATH!\" -c !CTX_LEN! -np 1 --port 39600 --host 127.0.0.1 --jinja !GPU_ARGS! --no-warmup' -RedirectStandardError '!HERMES_HOME!\logs\llama-server.err' -WindowStyle Hidden -PassThru | Select-Object -ExpandProperty Id"`) do (
            set "NEW_LLAMA_PID=%%p"
        )
        
        if defined NEW_LLAMA_PID (
            echo !NEW_LLAMA_PID!>"%HERMES_HOME%\llama-server.pid"
            echo %BRIGHT_GREEN%llama-server started with PID !NEW_LLAMA_PID!.%RESET%
            echo %CYAN%Waiting for llama-server to be ready...%RESET%
            powershell -Command "$start = Get-Date; while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds(90)) { try { $res = Invoke-RestMethod -Uri 'http://127.0.0.1:39600/health' -ErrorAction SilentlyContinue; if ($res -and $res.status -eq 'ok') { exit 0 } } catch {} Start-Sleep -Seconds 1 }; exit 1"
            if !errorlevel! neq 0 (
                echo %RED%Error: llama-server failed to become ready in time.%RESET%
                pause
                exit /b 1
            )
            echo %GREEN%llama-server is ready.%RESET%
        ) else (
            echo %RED%Error: Failed to start llama-server.%RESET%
            pause
            exit /b 1
        )
    )
)
exit /b 0

:stop_llama_server
if exist "%HERMES_HOME%\llama-server.pid" (
    set /p LLAMA_PID=<"%HERMES_HOME%\llama-server.pid"
    if defined LLAMA_PID (
        taskkill /PID !LLAMA_PID! /F >nul 2>&1
        echo %CYAN%Stopped local llama-server.%RESET%
    )
    del "%HERMES_HOME%\llama-server.pid" >nul 2>&1
)
exit /b 0

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
python -c "from hermes_cli.main import main; main()" doctor
pause
goto :show_advanced

:adv_logs
echo.
if exist "%HERMES_HOME%\logs\gateway.log" (
    echo %CYAN%=== Gateway Log (last 20 lines) ===%RESET%
    powershell -Command "Get-Content '%HERMES_HOME%\logs\gateway.log' -Tail 20"
) else (
    echo %YELLOW%No logs found.%RESET%
)
echo.
pause
goto :show_advanced

:adv_config
echo.
python -c "from hermes_cli.main import main; main()" config edit
goto :show_advanced

:adv_restart
python -c "from hermes_cli.main import main; main()" gateway restart
echo.
echo %BRIGHT_GREEN%Gateway restarted.%RESET%
pause
goto :detect_status

:adv_update
echo.
python -c "from hermes_cli.main import main; main()" update
pause
goto :show_advanced
