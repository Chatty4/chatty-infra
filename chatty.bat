@echo off
:: The Chatty dev menu: one place for every script in this folder. Double-click it.
:: Each script also works on its own and with arguments; see the top of each file.
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
:: The scripts below pause on their own when double-clicked; here the menu pauses instead.
set "CHATTY_NO_PAUSE=1"
title Chatty

:menu
cls
call "%LIB%" :title "Chatty"
docker info >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :warn "Docker is not running. Start can start it for you."
) else (
    call "%LIB%" :status_table
)
echo.
call "%LIB%" :menu_item 1 "Start" "start everything, infra only, or chosen services"
call "%LIB%" :menu_item 2 "Stop" "stop or remove containers, data is kept"
call "%LIB%" :menu_item 3 "Restart" "restart, recreate or rebuild services"
call "%LIB%" :menu_item 4 "Migrations" "status, apply, make, check, rollback"
call "%LIB%" :menu_item 5 "Logs" "follow, last lines, errors only"
call "%LIB%" :menu_item 6 "Status" "containers, app health, repos"
call "%LIB%" :menu_item 7 "Tests and lint" "same checks as CI, or fix lint"
call "%LIB%" :menu_item 8 "Shell" "Django shell, bash, psql, redis-cli, MinIO"
call "%LIB%" :menu_item 9 "Reset databases" "wipe core_db, chat_db or everything, with a backup"
call "%LIB%" :menu_item 0 "Setup" "clone missing repos, .env files, virtualenvs"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 1234567890Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="11" goto :end
for /f "tokens=%CH%" %%s in ("start stop restart migrate logs status test shell reset-db setup") do set "SCRIPT=%%s"
cls
call "%ROOT%\!SCRIPT!.bat"
echo.
echo   %C_DIM%Press any key to go back to the menu ...%C_RESET%
pause >nul
goto :menu

:end
endlocal
exit /b 0
