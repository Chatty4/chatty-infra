@echo off
:: Opens a shell inside a container: Django or Python shells, bash, psql, redis-cli.
::
::   shell.bat                  menu
::   shell.bat <name>           django, core-bash, python, chat-bash, psql-core, psql-chat, redis, minio
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Shell"

set "PICK=%~1"
if defined PICK (set "INTERACTIVE=0") else set "INTERACTIVE=1"
call "%LIB%" :check_docker || goto :failed
if "%INTERACTIVE%"=="0" goto :run

call "%LIB%" :menu_item 1 "Django shell" "chatty-core: python manage.py shell"
call "%LIB%" :menu_item 2 "core bash" "a shell in the chatty-core container"
call "%LIB%" :menu_item 3 "Python" "chatty-chat: python, with the app importable"
call "%LIB%" :menu_item 4 "chat bash" "a shell in the chatty-chat container"
call "%LIB%" :menu_item 5 "psql core_db" "Postgres for chatty-core"
call "%LIB%" :menu_item 6 "psql chat_db" "Postgres for chatty-chat"
call "%LIB%" :menu_item 7 "redis-cli"
call "%LIB%" :menu_item 8 "MinIO console" "opens the browser"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 12345678Q /n /m "  Choose: "
set "CH=!errorlevel!"
for /f "tokens=%CH%" %%p in ("django core-bash python chat-bash psql-core psql-chat redis minio") do set "PICK=%%p"
if not defined PICK goto :end

:run
echo.
if /i "!PICK!"=="django" call :open core python manage.py shell
if /i "!PICK!"=="core-bash" call :open core bash
if /i "!PICK!"=="python" call :open chat python
if /i "!PICK!"=="chat-bash" call :open chat bash
if /i "!PICK!"=="psql-core" call :open core-db psql -U %CFG_CORE_DB_USER% -d %CFG_CORE_DB_NAME%
if /i "!PICK!"=="psql-chat" call :open chat-db psql -U %CFG_CHAT_DB_USER% -d %CFG_CHAT_DB_NAME%
if /i "!PICK!"=="redis" call :open redis redis-cli
if /i "!PICK!"=="minio" (
    call "%LIB%" :ensure_running minio || goto :failed
    call "%LIB%" :info "Opening http://127.0.0.1:%CFG_MINIO_CONSOLE_PORT%"
    call "%LIB%" :hint "User: %CFG_MINIO_ROOT_USER%  Password: see MINIO_ROOT_PASSWORD in chatty-infra\.env or .env.example"
    start "" "http://127.0.0.1:%CFG_MINIO_CONSOLE_PORT%"
)
goto :end

:open
:: open <service> <command...>
set "_svc=%~1"
shift
set "_cmd="
:open_args
if "%~1"=="" goto :open_run
set "_cmd=!_cmd! %1"
shift
goto :open_args
:open_run
call "%LIB%" :ensure_running !_svc! || exit /b 1
call "%LIB%" :info "!_svc!:!_cmd!   - type exit, or \q in psql, to leave"
echo.
docker compose exec !_svc!!_cmd!
exit /b 0

:end
call "%LIB%" :finish
exit /b 0

:failed
call "%LIB%" :finish
exit /b 1
