@echo off
:: Stops the Chatty stack. Data in the Docker volumes is always kept; reset-db.bat deletes data.
::
::   stop.bat                     menu
::   stop.bat all                 stop every container, keep them for a fast start
::   stop.bat apps                stop chatty-core and chatty-chat, keep infra running
::   stop.bat down                remove the containers and network, keep the data
::   stop.bat core redis ...      stop chosen services
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Stop"

set "MODE=%~1"
if defined MODE (set "INTERACTIVE=0") else set "INTERACTIVE=1"

call "%LIB%" :check_docker || goto :failed
echo.
call "%LIB%" :status_table
echo.

if "%INTERACTIVE%"=="0" goto :run

echo   What do you want to stop?
echo.
call "%LIB%" :menu_item 1 "Everything" "containers are kept, start.bat brings them back in seconds"
call "%LIB%" :menu_item 2 "Apps only" "chatty-core and chatty-chat, infra keeps running"
call "%LIB%" :menu_item 3 "Pick services" "choose one or more"
call "%LIB%" :menu_item 4 "Remove containers" "docker compose down. Data in volumes is kept"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 1234Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="1" set "MODE=all"
if "!CH!"=="2" set "MODE=apps"
if "!CH!"=="4" set "MODE=down"
if not "!CH!"=="3" goto :run
call "%LIB%" :pick_services "Services to stop" "%ALL_SERVICES%" || goto :cancel
set "MODE=!SELECTED!"

:run
if not defined MODE goto :cancel

if /i "!MODE!"=="down" goto :down

if /i "!MODE!"=="all" (
    call "%LIB%" :info "Stopping every container ..."
    docker compose stop
    if errorlevel 1 goto :failed
    goto :done
)

call "%LIB%" :resolve_targets "!MODE!"
if not defined SELECTED goto :cancel
call "%LIB%" :info "Stopping: !SELECTED! ..."
docker compose stop !SELECTED!
if errorlevel 1 goto :failed
goto :done

:down
if "%INTERACTIVE%"=="1" (
    echo.
    call "%LIB%" :info "This removes the containers and the network. Volumes, so all data, stay."
    call "%LIB%" :confirm "Back up core_db and chat_db first?"
    if "!CONFIRMED!"=="1" (
        call "%LIB%" :timestamp
        call "%LIB%" :backup_db core-db %CFG_CORE_DB_USER% %CFG_CORE_DB_NAME% "%BACKUP_ROOT%\!STAMP!"
        call "%LIB%" :backup_db chat-db %CFG_CHAT_DB_USER% %CFG_CHAT_DB_NAME% "%BACKUP_ROOT%\!STAMP!"
    )
)
call "%LIB%" :info "Removing containers ..."
docker compose down
if errorlevel 1 goto :failed

:done
echo.
call "%LIB%" :ok "Done. Data in the volumes is kept."
echo.
call "%LIB%" :status_table
echo.
call "%LIB%" :hint "start.bat brings everything back."
call "%LIB%" :finish
exit /b 0

:cancel
echo.
call "%LIB%" :info "Nothing stopped."
call "%LIB%" :finish
exit /b 0

:failed
echo.
call "%LIB%" :err "Stop failed. See the output above."
call "%LIB%" :finish
exit /b 1
