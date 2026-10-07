@echo off
:: What is running, whether the apps answer, and where each repo stands.
::
::   status.bat            show it, then R to refresh, W to watch, Q to quit
::   status.bat --once     show it once and exit
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
if /i "%~1"=="--once" (set "INTERACTIVE=0") else set "INTERACTIVE=1"
set "WATCH=0"

:show
if "!WATCH!"=="1" cls
call "%LIB%" :title "Chatty - Status"

docker info >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :warn "Docker is not running. start.bat can start it."
    goto :repos
)

echo %C_BOLD%  Containers%C_RESET%
call "%LIB%" :status_table

echo.
echo %C_BOLD%  Apps%C_RESET%
call :app_health core "http://127.0.0.1:%CFG_CORE_API_PORT%/health"
call :app_health chat "http://127.0.0.1:%CFG_CHAT_API_PORT%/health"

:repos
echo.
echo %C_BOLD%  Repos%C_RESET%
echo     %C_DIM%REPO           BRANCH                          CHANGES   SYNC, as of the last fetch%C_RESET%
for %%r in (.github chatty-core chatty-chat chatty-infra chatty-web) do call :repo_line %%r

echo.
if "%INTERACTIVE%"=="0" exit /b 0
if "!WATCH!"=="1" (
    choice /c RQ /n /t 5 /d R /m "  Refreshing every 5 seconds. Q to stop: "
    if errorlevel 2 goto :end
    goto :show
)
choice /c RWQ /n /m "  R refresh, W watch every 5 seconds, Q quit: "
if errorlevel 3 goto :end
if errorlevel 2 set "WATCH=1"
goto :show

:end
call "%LIB%" :finish
exit /b 0


:app_health
call "%LIB%" :is_running %~1
if errorlevel 1 (
    echo     %C_BOLD%%~1%C_RESET%      %C_DIM%not running%C_RESET%
    exit /b 0
)
set "_body="
for /f "delims=" %%b in ('curl.exe -s --max-time 3 "%~2" 2^>nul') do set "_body=%%b"
call "%LIB%" :http_code "%~2"
set "_color=%C_RED%"
if "!HTTP_CODE!"=="200" set "_color=%C_GREEN%"
if "!HTTP_CODE!"=="503" set "_color=%C_YELLOW%"
echo     %C_BOLD%%~1%C_RESET%      !_color!!HTTP_CODE!%C_RESET%  %~2  %C_DIM%!_body!%C_RESET%
exit /b 0

:repo_line
set "_dir=%WORKSPACE%\%~1"
set "_name=%~1               "
if not exist "!_dir!\.git" (
    echo     !_name:~0,14! %C_DIM%not cloned%C_RESET%
    exit /b 0
)
set "_branch=?"
set "_changes=0"
set "_sync=no upstream"
for /f "delims=" %%b in ('git -C "!_dir!" branch --show-current 2^>nul') do set "_branch=%%b"
for /f %%c in ('git -C "!_dir!" status --porcelain 2^>nul ^| find /c /v ""') do set "_changes=%%c"
for /f "tokens=1,2" %%a in ('git -C "!_dir!" rev-list --left-right --count @{u}...HEAD 2^>nul') do (
    set "_sync=up to date"
    if not "%%b"=="0" set "_sync=%%b to push"
    if not "%%a"=="0" set "_sync=%%a to pull"
    if not "%%a"=="0" if not "%%b"=="0" set "_sync=%%b to push, %%a to pull"
)
set "_branch=!_branch!                                "
set "_ch=%C_GREEN%clean    %C_RESET%"
if not "!_changes!"=="0" (
    set "_ch=!_changes! files          "
    set "_ch=%C_YELLOW%!_ch:~0,9!%C_RESET%"
)
echo     !_name:~0,14! !_branch:~0,31! !_ch! %C_DIM%!_sync!%C_RESET%
exit /b 0
