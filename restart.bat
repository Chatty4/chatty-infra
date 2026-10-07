@echo off
:: Restarts services, three ways:
::   restart     same container. Code changes are already live through --reload; use it when stuck
::   recreate    new container: applies changes to docker-compose.yml or .env
::   rebuild     new image and container: needed after requirements.txt or Dockerfile changes
::
::   restart.bat                              menu
::   restart.bat core chat                    restart
::   restart.bat core --recreate              recreate
::   restart.bat apps --build                 rebuild
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Restart"

set "HOW=restart"
set "TARGETS="
for %%a in (%*) do (
    if /i "%%a"=="--recreate" (
        set "HOW=recreate"
    ) else if /i "%%a"=="--build" (
        set "HOW=rebuild"
    ) else (
        set "TARGETS=!TARGETS! %%a"
    )
)
if defined TARGETS (set "INTERACTIVE=0") else set "INTERACTIVE=1"

call "%LIB%" :check_docker || goto :failed
if "%INTERACTIVE%"=="0" goto :resolve

call "%LIB%" :pick_services "Services to restart" "%ALL_SERVICES%" || goto :cancel
set "TARGETS=!SELECTED!"
echo.
echo   How?
echo.
call "%LIB%" :menu_item 1 "Restart" "quick, same container. Code is already live via --reload; use when stuck"
call "%LIB%" :menu_item 2 "Recreate" "applies changes to docker-compose.yml or .env"
call "%LIB%" :menu_item 3 "Rebuild" "new image; needed after requirements.txt or Dockerfile changes"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 123Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="1" set "HOW=restart"
if "!CH!"=="2" set "HOW=recreate"
if "!CH!"=="3" set "HOW=rebuild"
if "!CH!"=="4" goto :cancel

:resolve
call "%LIB%" :resolve_targets "!TARGETS!"
call "%LIB%" :drop_missing_repos
if not defined SELECTED goto :cancel

echo.
call "%LIB%" :info "!HOW!: !SELECTED!"
echo.
if "!HOW!"=="restart" (
    docker compose restart !SELECTED!
    if errorlevel 1 goto :problems
    rem restart doesn't wait for health checks; up --wait on running containers only waits.
    call "%LIB%" :compose_up "!SELECTED!"
) else if "!HOW!"=="recreate" (
    call "%LIB%" :compose_up "!SELECTED!" --force-recreate
) else (
    call "%LIB%" :compose_up "!SELECTED!" --build --force-recreate
)
if errorlevel 1 goto :problems

echo.
call "%LIB%" :check_apps "!SELECTED!"
echo.
call "%LIB%" :status_table
call "%LIB%" :finish
exit /b 0

:problems
call "%LIB%" :show_problems "!SELECTED!"
goto :failed

:cancel
echo.
call "%LIB%" :info "Nothing restarted."
call "%LIB%" :finish
exit /b 0

:failed
echo.
call "%LIB%" :err "Restart failed. See the output above."
call "%LIB%" :finish
exit /b 1
