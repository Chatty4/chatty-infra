@echo off
:: Shows container logs.
::
::   logs.bat                     menu
::   logs.bat core                follow core live
::   logs.bat apps                follow core and chat together
::   logs.bat all                 follow everything
::   logs.bat chat --errors       only error, exception, traceback and warning lines
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Logs"

set "TARGET=%~1"
set "MODE=follow"
if /i "%~2"=="--errors" set "MODE=errors"
if /i "%~2"=="--last" set "MODE=last"
if defined TARGET (set "INTERACTIVE=0") else set "INTERACTIVE=1"

call "%LIB%" :check_docker || goto :failed
if "%INTERACTIVE%"=="0" goto :run

echo   Whose logs?
call "%LIB%" :pick_one "Choose:" "%ALL_SERVICES% apps all" || goto :cancel
set "TARGET=!SELECTED!"
echo.
echo   How?
echo.
call "%LIB%" :menu_item 1 "Follow live" "new lines as they come. Ctrl+C, then N, to stop"
call "%LIB%" :menu_item 2 "Last 200 lines"
call "%LIB%" :menu_item 3 "Errors only" "error, exception, traceback and warning lines from the last 2000"
call "%LIB%" :menu_item Q "Back"
echo.
choice /c 123Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="1" set "MODE=follow"
if "!CH!"=="2" set "MODE=last"
if "!CH!"=="3" set "MODE=errors"
if "!CH!"=="4" goto :cancel

:run
:: "all" means no service argument; "apps" means both apps.
set "SERVICES=!TARGET!"
if /i "!TARGET!"=="all" set "SERVICES="
if /i "!TARGET!"=="apps" set "SERVICES=%APP_SERVICES%"
if defined SERVICES (
    for %%s in (!SERVICES!) do (
        call "%LIB%" :is_service %%s || (
            call "%LIB%" :err "Unknown service: %%s"
            goto :failed
        )
    )
)

echo.
if "!MODE!"=="follow" (
    call "%LIB%" :info "Following !TARGET!. Press Ctrl+C, then N, to stop."
    echo.
    docker compose logs -f --tail 100 !SERVICES!
) else if "!MODE!"=="last" (
    docker compose logs --no-color --tail 200 !SERVICES!
) else (
    call "%LIB%" :info "Lines with error, exception, traceback or warn in the last 2000 lines of !TARGET!:"
    echo.
    docker compose logs --no-color --tail 2000 !SERVICES! | findstr /i /c:"error" /c:"exception" /c:"traceback" /c:"warn" /c:"critical" /c:"fatal"
    if errorlevel 1 call "%LIB%" :ok "Nothing found."
)
call "%LIB%" :finish
exit /b 0

:cancel
call "%LIB%" :finish
exit /b 0

:failed
call "%LIB%" :finish
exit /b 1
