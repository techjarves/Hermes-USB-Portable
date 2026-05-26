@echo off
setlocal enabledelayedexpansion

REM ============================================================================
REM Hermes Agent - Portable Launcher (Windows)
REM ============================================================================
REM Double-click this file to launch Hermes.
REM On first run, it downloads ~600MB of runtime files automatically.
REM All data stays in the "data\" folder - nothing touches the host computer.
REM
REM Portability: on every launch the venv is self-healed (scripts\heal-venv.ps1)
REM so the folder works on any drive letter / machine with no rebuild, and Hermes
REM is started via "python -m hermes_cli.main" instead of the path-baked hermes.exe.
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
REM Self-heal: make the venv drive/path agnostic (idempotent, local, no network)
if exist "%RUNTIME_DIR%\venv\pyvenv.cfg" (
    powershell -ExecutionPolicy Bypass -File "%PORTABLE_ROOT%\scripts\heal-venv.ps1" -Root "%PORTABLE_ROOT%" >nul 2>&1
)

set "VIRTUAL_ENV=%RUNTIME_DIR%\venv"
set "VENV_PYTHON=%VIRTUAL_ENV%\Scripts\python.exe"
set "PATH=%VIRTUAL_ENV%\Scripts;%RUNTIME_DIR%\python;%RUNTIME_DIR%\python\Scripts;%RUNTIME_DIR%\node;%RUNTIME_DIR%\uv;%RUNTIME_DIR%\bin;%PATH%"
set "PYTHONNOUSERSITE=1"
set "PYTHONHOME="
set "PYTHONPATH=%SRC_DIR%\hermes-agent"
set "UV_NO_CONFIG=1"
set "UV_PYTHON=%RUNTIME_DIR%\python\python.exe"
set "PLAYWRIGHT_BROWSERS_PATH=%RUNTIME_DIR%\playwright"
set "NODE_PATH=%RUNTIME_DIR%\node\node_modules"
set "NPM_CONFIG_PREFIX=%RUNTIME_DIR%\node"

REM Prevent Node from writing to host appdata
set "APPDATA=%PORTABLE_ROOT%\.cache\windows-appdata"
set "LOCALAPPDATA=%PORTABLE_ROOT%\.cache\windows-localappdata"

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

REM If explicit arguments were passed, run Hermes directly (skip menu)
if not "%ARGS%"=="" (
    "%VENV_PYTHON%" -m hermes_cli.main %ARGS%
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
echo  %DIM%Version%RESET%  %GRAY%v!HERMES_VERSION!%RESET%
echo.
echo %BRIGHT_CYAN%----------------------------------------------------------------%RESET%
echo.
echo  %BRIGHT_YELLOW%[1]%RESET%  %WHITE%Start Hermes Chat%RESET%
echo  %BRIGHT_YELLOW%[2]%RESET%  %WHITE%Setup / Reconfigure Hermes%RESET%
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

echo %BRIGHT_CYAN%Select option:%RESET% & choice /C 12345 /N
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
"%VENV_PYTHON%" -m hermes_cli.main
goto :show_menu

:menu_setup
echo.
"%VENV_PYTHON%" -m hermes_cli.main setup
goto :detect_status

:menu_gateway
if "!GATEWAY_STATUS!"=="Running (PID !GATEWAY_PID!)" (
    "%VENV_PYTHON%" -m hermes_cli.main gateway stop
    echo.
    echo %BRIGHT_GREEN%Gateway stopped.%RESET%
) else (
    echo.
    echo %CYAN%Starting gateway in background ...%RESET%
    start "" "%VENV_PYTHON%" -m hermes_cli.main gateway
    timeout /t 2 /nobreak >nul
)
pause
goto :detect_status

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
"%VENV_PYTHON%" -m hermes_cli.main doctor
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
"%VENV_PYTHON%" -m hermes_cli.main config edit
goto :show_advanced

:adv_restart
"%VENV_PYTHON%" -m hermes_cli.main gateway restart
echo.
echo %BRIGHT_GREEN%Gateway restarted.%RESET%
pause
goto :detect_status

:adv_update
echo.
"%VENV_PYTHON%" -m hermes_cli.main update
pause
goto :show_advanced
