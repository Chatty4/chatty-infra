@echo off
:: Wipes databases. Always asks: there is no way to run it without answering.
::
:: Backs up every database it is about to wipe into backups\<date>\ first, and asks again if a
:: backup fails. A database reset stops the app that uses it, drops and recreates the database,
:: starts the app again and offers to migrate.
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Reset databases"
set "INTERACTIVE=1"

call "%LIB%" :check_docker || goto :failed
echo.
call "%LIB%" :status_table
echo.
echo   What do you want to wipe?
echo.
call "%LIB%" :menu_item 1 "core_db" "chatty-core: users, teams, channels, ..."
call "%LIB%" :menu_item 2 "chat_db" "chatty-chat: messages, reactions, read state, ..."
call "%LIB%" :menu_item 3 "Both databases"
call "%LIB%" :menu_item 4 "Everything" "every volume: both databases, Redis, MinIO files, Kafka topics"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 1234Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="5" goto :cancel
set "DBS="
if "!CH!"=="1" set "DBS=core"
if "!CH!"=="2" set "DBS=chat"
if "!CH!"=="3" set "DBS=core chat"
if "!CH!"=="4" set "DBS=core chat"
set "EVERYTHING=0"
if "!CH!"=="4" set "EVERYTHING=1"

:: ---- Back up ------------------------------------------------------------------------------
call "%LIB%" :step 1 3 "Backing up"
call "%LIB%" :timestamp
set "BACKUP_DIR=%BACKUP_ROOT%\!STAMP!"
set "BACKUP_FAILED=0"
for %%d in (!DBS!) do (
    call :db_vars %%d
    call "%LIB%" :is_running !DB_SVC!
    if errorlevel 1 (
        call "%LIB%" :info "Starting !DB_SVC! to take the backup ..."
        docker compose up -d --wait --wait-timeout 120 !DB_SVC! >nul 2>&1
    )
    call "%LIB%" :backup_db !DB_SVC! !DB_USER! !DB_NAME! "!BACKUP_DIR!"
    if "!BACKUP_OK!"=="0" set "BACKUP_FAILED=1"
)
if "!EVERYTHING!"=="1" call "%LIB%" :warn "Redis keys, MinIO files and Kafka topics are not backed up."

:: ---- Confirm ------------------------------------------------------------------------------
call "%LIB%" :step 2 3 "Confirm"
if "!EVERYTHING!"=="1" (
    call "%LIB%" :warn "This deletes every Chatty volume: core_db, chat_db, Redis, MinIO and Kafka."
) else (
    for %%d in (!DBS!) do (
        call :db_vars %%d
        call "%LIB%" :warn "This deletes everything in !DB_NAME!."
    )
)
if "!BACKUP_FAILED!"=="1" (
    call "%LIB%" :err "At least one backup failed. That data cannot be brought back."
)
echo.
call "%LIB%" :type_to_confirm DESTROY ""
if "!CONFIRMED!"=="0" goto :cancel
if "!BACKUP_FAILED!"=="1" (
    call "%LIB%" :type_to_confirm DESTROY "Without a backup."
    if "!CONFIRMED!"=="0" goto :cancel
)

:: ---- Wipe ---------------------------------------------------------------------------------
call "%LIB%" :step 3 3 "Wiping"
if "!EVERYTHING!"=="1" goto :wipe_everything

for %%d in (!DBS!) do (
    call :db_vars %%d
    call :wipe_db %%d
    if errorlevel 1 goto :failed
)
call :offer_migrate
goto :done

:wipe_everything
docker compose down -v
if errorlevel 1 goto :failed
call "%LIB%" :ok "Every container and volume removed."
echo.
call "%LIB%" :confirm "Start everything again now?"
if "!CONFIRMED!"=="1" (
    set "CHATTY_NO_PAUSE=1"
    call "%ROOT%\start.bat" all
    call :offer_migrate
)
goto :done


:db_vars
:: db_vars <core|chat> -> DB_SVC, DB_USER, DB_NAME
if "%~1"=="core" (
    set "DB_SVC=core-db"
    set "DB_USER=%CFG_CORE_DB_USER%"
    set "DB_NAME=%CFG_CORE_DB_NAME%"
) else (
    set "DB_SVC=chat-db"
    set "DB_USER=%CFG_CHAT_DB_USER%"
    set "DB_NAME=%CFG_CHAT_DB_NAME%"
)
exit /b 0

:wipe_db
:: wipe_db <core|chat>: stop the app, drop and recreate its database, start the app again if it ran
call :db_vars %~1
set "APP_WAS_RUNNING=0"
call "%LIB%" :is_running %~1 && set "APP_WAS_RUNNING=1"
if "!APP_WAS_RUNNING!"=="1" (
    call "%LIB%" :info "Stopping %~1 so nothing writes while the database is recreated ..."
    docker compose stop %~1 >nul 2>&1
)
call "%LIB%" :info "Recreating !DB_NAME! ..."
docker compose exec -T !DB_SVC! psql -U !DB_USER! -d postgres -v ON_ERROR_STOP=1 -q -c "DROP DATABASE IF EXISTS !DB_NAME! WITH (FORCE);" -c "CREATE DATABASE !DB_NAME! OWNER !DB_USER!;"
if errorlevel 1 (
    call "%LIB%" :err "Could not recreate !DB_NAME!."
    exit /b 1
)
call "%LIB%" :ok "!DB_NAME! is empty."
if "!APP_WAS_RUNNING!"=="1" (
    call "%LIB%" :info "Starting %~1 again ..."
    docker compose up -d --wait --wait-timeout 180 %~1 >nul 2>&1
)
exit /b 0

:offer_migrate
echo.
call "%LIB%" :confirm "Run migrations on the empty databases now?"
if "!CONFIRMED!"=="0" exit /b 0
set "_t=!DBS!"
if "!_t!"=="core chat" set "_t=all"
:: migrate.bat refuses core_db while the custom User model doesn't exist and explains why.
set "CHATTY_NO_PAUSE=1"
call "%ROOT%\migrate.bat" !_t! apply
exit /b 0

:done
echo.
call "%LIB%" :ok "Reset complete."
if exist "!BACKUP_DIR!" (
    call "%LIB%" :hint "Backups: !BACKUP_DIR!"
    call "%LIB%" :hint "Restore one into an empty database, e.g. core_db:"
    rem Echoed here, not through :hint: CALL doubles the caret that escapes the redirect.
    echo          %C_DIM%docker compose exec -T core-db psql -U %CFG_CORE_DB_USER% -d %CFG_CORE_DB_NAME% ^< "!BACKUP_DIR!\%CFG_CORE_DB_NAME%.sql"%C_RESET%
)
call "%LIB%" :finish
exit /b 0

:cancel
echo.
call "%LIB%" :info "Aborted. Nothing was deleted."
if exist "!BACKUP_DIR!" call "%LIB%" :hint "The backups taken are kept in !BACKUP_DIR!"
call "%LIB%" :finish
exit /b 0

:failed
echo.
call "%LIB%" :err "Reset failed. See the output above."
if exist "!BACKUP_DIR!" call "%LIB%" :hint "Backups: !BACKUP_DIR!"
call "%LIB%" :finish
exit /b 1
