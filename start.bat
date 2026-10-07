@echo off
:: Starts the Chatty stack in Docker.
::
::   start.bat                       menu
::   start.bat all [--build]         infra + chatty-core + chatty-chat
::   start.bat infra                 only infra, to run core or chat yourself with uvicorn
::   start.bat apps                  chatty-core + chatty-chat and the infra they need
::   start.bat core redis ...        chosen services; their dependencies start too
::
:: --build rebuilds the app images first: needed after requirements.txt or Dockerfile changes.
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Start"

set "BUILD="
set "TARGETS="
for %%a in (%*) do (
    if /i "%%a"=="--build" (set "BUILD=--build") else set "TARGETS=!TARGETS! %%a"
)
if defined TARGETS (set "INTERACTIVE=0") else set "INTERACTIVE=1"
if "%INTERACTIVE%"=="0" goto :resolve

echo   What do you want to start?
echo.
call "%LIB%" :menu_item 1 "Everything" "infra, chatty-core and chatty-chat"
call "%LIB%" :menu_item 2 "Infra only" "Postgres x2, Redis, MinIO, Kafka. Run core or chat with uvicorn"
call "%LIB%" :menu_item 3 "Apps" "chatty-core and chatty-chat, plus the infra they need"
call "%LIB%" :menu_item 4 "Pick services" "choose one or more"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 1234Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="1" set "TARGETS=all"
if "!CH!"=="2" set "TARGETS=infra"
if "!CH!"=="3" set "TARGETS=apps"
if not "!CH!"=="4" goto :resolve
call "%LIB%" :pick_services "Services to start" "%ALL_SERVICES%" || goto :cancel
set "TARGETS=!SELECTED!"

:resolve
if not defined TARGETS goto :cancel
call "%LIB%" :resolve_targets "!TARGETS!"
call "%LIB%" :drop_missing_repos
if not defined SELECTED goto :cancel

:: Ask about rebuilding only when an app is in the list and --build wasn't passed.
if "%INTERACTIVE%"=="0" goto :preflight
if defined BUILD goto :preflight
call "%LIB%" :selection_has_app || goto :preflight
echo.
call "%LIB%" :confirm "Rebuild the app images? Only needed after requirements.txt or Dockerfile changes."
if "!CONFIRMED!"=="1" set "BUILD=--build"

:preflight
call "%LIB%" :step 1 3 "Checking prerequisites"
call "%LIB%" :check_docker || goto :failed
call "%LIB%" :check_env_files
call "%LIB%" :check_app_ports || goto :cancel

call "%LIB%" :step 2 3 "Starting: !SELECTED!"
if defined BUILD call "%LIB%" :info "Rebuilding app images first, this can take a few minutes."
call "%LIB%" :info "Waiting for health checks, up to 3 minutes ..."
echo.
call "%LIB%" :compose_up "!SELECTED!" !BUILD!
if errorlevel 1 (
    call "%LIB%" :show_problems "!SELECTED!"
    goto :failed
)

call "%LIB%" :step 3 3 "Checking the apps"
call "%LIB%" :selection_has_app
if errorlevel 1 (
    call "%LIB%" :info "No apps selected."
) else (
    call "%LIB%" :check_apps "!SELECTED!"
)

echo.
call "%LIB%" :status_table
echo.
call "%LIB%" :is_running core
if not errorlevel 1 (
    call "%LIB%" :core_has_user_model
    if errorlevel 1 call "%LIB%" :hint "core_db is not migrated on purpose until the custom User model exists. See migrate.bat."
)
call "%LIB%" :hint "Next: logs.bat to follow logs, migrate.bat for migrations, stop.bat to stop."
call "%LIB%" :finish
exit /b 0

:cancel
echo.
call "%LIB%" :info "Nothing started."
call "%LIB%" :finish
exit /b 0

:failed
echo.
call "%LIB%" :err "Start failed. See the output above."
call "%LIB%" :hint "logs.bat shows the full logs. status.bat shows what is running."
call "%LIB%" :finish
exit /b 1
