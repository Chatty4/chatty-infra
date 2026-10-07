@echo off
:: Shared helpers for the chatty-infra .bat scripts. Not meant to be run on its own.
::
:: Every script starts with:
::     setlocal EnableDelayedExpansion
::     call "%~dp0scripts\lib.bat" :init || exit /b 1
:: and then calls helpers as:  call "%LIB%" :ok "Message"
::
:: Helpers run in the caller's environment (there is no setlocal here), so the variables they set
:: (STATE, SELECTED, CONFIRMED, HTTP_CODE, ...) are visible to the calling script.
:: Delayed expansion is on in every caller: keep "!" out of messages, it gets eaten.
:: Keep "&", "|", "<", ">" and parentheses out of messages too, cmd reads them as syntax.
call %*
exit /b


:: =============================================================================================
:: Setup
:: =============================================================================================

:init
for %%i in ("%~dp0..") do set "ROOT=%%~fi"
for %%i in ("%ROOT%\..") do set "WORKSPACE=%%~fi"
set "LIB=%ROOT%\scripts\lib.bat"
set "CORE_DIR=%WORKSPACE%\chatty-core"
set "CHAT_DIR=%WORKSPACE%\chatty-chat"
set "BACKUP_ROOT=%ROOT%\backups"
:: docker compose reads COMPOSE_FILE, so every "docker compose ..." uses this file and its .env,
:: whatever folder the script was started from.
set "COMPOSE_FILE=%ROOT%\docker-compose.yml"

:: The one list of services. Start order; container names are chatty-<service>.
set "INFRA_SERVICES=core-db chat-db redis minio kafka"
set "APP_SERVICES=core chat"
set "ALL_SERVICES=%APP_SERVICES% %INFRA_SERVICES%"

:: Colors (Windows 10+). Set NO_COLOR=1 to turn them off.
set "C_RESET=" & set "C_BOLD=" & set "C_DIM=" & set "C_RED=" & set "C_GREEN=" & set "C_YELLOW=" & set "C_CYAN="
if not defined NO_COLOR (
    for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
)
if defined ESC (
    set "C_RESET=!ESC![0m"
    set "C_BOLD=!ESC![1m"
    set "C_DIM=!ESC![90m"
    set "C_RED=!ESC![91m"
    set "C_GREEN=!ESC![92m"
    set "C_YELLOW=!ESC![93m"
    set "C_CYAN=!ESC![96m"
)

:: Settings as compose sees them: .env.example, then .env on top. Stored as CFG_<NAME> so they
:: never leak into docker compose as real environment variables.
call :load_env "%ROOT%\.env.example"
if exist "%ROOT%\.env" call :load_env "%ROOT%\.env"
if not defined CFG_CORE_DB_USER set "CFG_CORE_DB_USER=core_user"
if not defined CFG_CORE_DB_NAME set "CFG_CORE_DB_NAME=core_db"
if not defined CFG_CORE_DB_PORT set "CFG_CORE_DB_PORT=5432"
if not defined CFG_CHAT_DB_USER set "CFG_CHAT_DB_USER=chat_user"
if not defined CFG_CHAT_DB_NAME set "CFG_CHAT_DB_NAME=chat_db"
if not defined CFG_CHAT_DB_PORT set "CFG_CHAT_DB_PORT=5433"
if not defined CFG_REDIS_PORT set "CFG_REDIS_PORT=6379"
if not defined CFG_MINIO_API_PORT set "CFG_MINIO_API_PORT=9000"
if not defined CFG_MINIO_CONSOLE_PORT set "CFG_MINIO_CONSOLE_PORT=9001"
if not defined CFG_KAFKA_PORT set "CFG_KAFKA_PORT=9092"
if not defined CFG_CORE_API_PORT set "CFG_CORE_API_PORT=8000"
if not defined CFG_CHAT_API_PORT set "CFG_CHAT_API_PORT=8001"

:: Double-clicked (or started from PowerShell): cmd was started with /c and the window closes when
:: the script ends, so pause at the end. chatty.bat sets CHATTY_NO_PAUSE and pauses itself.
:: %cmdcmdline%, not !cmdcmdline!: the left side of a pipe runs in a new cmd without delayed expansion.
set "PAUSE_AT_END=0"
if defined CHATTY_NO_PAUSE exit /b 0
echo(%cmdcmdline% | findstr /i /c:" /c " >nul && set "PAUSE_AT_END=1"
exit /b 0

:load_env
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%~1") do set "CFG_%%a=%%b"
exit /b 0


:: =============================================================================================
:: Output
:: =============================================================================================

:title
echo.
echo %C_CYAN%%C_BOLD%  ==============================================================%C_RESET%
echo %C_CYAN%%C_BOLD%    %~1%C_RESET%
echo %C_CYAN%%C_BOLD%  ==============================================================%C_RESET%
echo.
exit /b 0

:step
echo.
echo %C_BOLD%  [%~1/%~2] %~3%C_RESET%
exit /b 0

:ok
echo   %C_GREEN%[ OK ]%C_RESET% %~1
exit /b 0

:info
echo   %C_CYAN%[ .. ]%C_RESET% %~1
exit /b 0

:warn
echo   %C_YELLOW%[WARN]%C_RESET% %~1
exit /b 0

:err
echo   %C_RED%[FAIL]%C_RESET% %~1
exit /b 0

:hint
echo          %C_DIM%%~1%C_RESET%
exit /b 0

:menu_item
:: menu_item <key> <label> [description]
set "_label=%~2                        "
echo     %C_BOLD%%~1%C_RESET%  !_label:~0,20! %C_DIM%%~3%C_RESET%
exit /b 0

:finish
if "%PAUSE_AT_END%"=="1" (
    echo.
    pause
)
exit /b 0


:: =============================================================================================
:: Prompts
:: =============================================================================================

:confirm
:: confirm "Question" -> CONFIRMED=1 or 0 (single key, Y or N)
choice /c YN /n /m "  %C_BOLD%?%C_RESET% %~1 [Y/N] "
if errorlevel 2 (set "CONFIRMED=0") else set "CONFIRMED=1"
exit /b 0

:type_to_confirm
:: type_to_confirm <WORD> "Question" -> CONFIRMED=1 only if WORD is typed exactly
set "TYPED="
set /p "TYPED=  %C_BOLD%?%C_RESET% %~2 Type %C_RED%%~1%C_RESET% to continue, anything else aborts: "
if "!TYPED!"=="%~1" (set "CONFIRMED=1") else set "CONFIRMED=0"
exit /b 0

:pick_services
:: pick_services "Prompt" "<service list>" -> SELECTED, errorlevel 1 if cancelled.
:: Accepts numbers or names separated by spaces or commas, A for all, Q or Enter to cancel.
set "PICK_LIST=%~2"
set "SELECTED="
echo.
set /a _n=0
for %%s in (%PICK_LIST%) do (
    set /a _n+=1
    set "PICK_!_n!=%%s"
    call :state %%s
    set "_name=%%s            "
    echo     %C_BOLD%!_n!%C_RESET%  !_name:~0,10! %C_DIM%!STATE!%C_RESET%
)
echo     %C_BOLD%A%C_RESET%  all of them
echo     %C_BOLD%Q%C_RESET%  cancel
echo.
set "_ans="
set /p "_ans=  %~1, e.g. 1 3: "
if not defined _ans exit /b 1
if /i "!_ans!"=="q" exit /b 1
if /i "!_ans!"=="a" (
    set "SELECTED=%PICK_LIST%"
    exit /b 0
)
:: for splits on spaces and commas, so "1,3" and "1 3" both work.
for %%x in (!_ans!) do (
    if defined PICK_%%x (
        set "SELECTED=!SELECTED! !PICK_%%x!"
    ) else (
        call :is_service %%x && (set "SELECTED=!SELECTED! %%x") || call :warn "Unknown choice: %%x"
    )
)
if not defined SELECTED exit /b 1
set "SELECTED=!SELECTED:~1!"
exit /b 0

:pick_one
:: pick_one "Prompt" "<list>" -> SELECTED (one item), errorlevel 1 if cancelled. Up to 9 items.
:: "all" and "apps" in the list are shown as choices without a container state.
set "PICK_LIST=%~2"
set "SELECTED="
set "_keys="
echo.
set /a _n=0
for %%s in (%PICK_LIST%) do (
    set /a _n+=1
    set "PICK_!_n!=%%s"
    set "_keys=!_keys!!_n!"
    set "_name=%%s            "
    if /i "%%s"=="all" (
        echo     %C_BOLD%!_n!%C_RESET%  !_name:~0,10! %C_DIM%every service%C_RESET%
    ) else if /i "%%s"=="apps" (
        echo     %C_BOLD%!_n!%C_RESET%  !_name:~0,10! %C_DIM%core and chat%C_RESET%
    ) else (
        call :state %%s
        echo     %C_BOLD%!_n!%C_RESET%  !_name:~0,10! %C_DIM%!STATE!%C_RESET%
    )
)
echo     %C_BOLD%Q%C_RESET%  back
echo.
choice /c !_keys!Q /n /m "  %~1 "
set "_c=!errorlevel!"
if !_c! gtr !_n! exit /b 1
if !_c! lss 1 exit /b 1
for %%c in (!_c!) do set "SELECTED=!PICK_%%c!"
exit /b 0


:: =============================================================================================
:: Services and containers
:: =============================================================================================

:is_service
for %%s in (%ALL_SERVICES%) do if /i "%~1"=="%%s" exit /b 0
exit /b 1

:resolve_targets
:: resolve_targets "<words>" -> SELECTED. Words: all, infra, apps or service names.
set "SELECTED="
for %%a in (%~1) do (
    if /i "%%a"=="all" (
        set "SELECTED=!SELECTED! %ALL_SERVICES%"
    ) else if /i "%%a"=="infra" (
        set "SELECTED=!SELECTED! %INFRA_SERVICES%"
    ) else if /i "%%a"=="apps" (
        set "SELECTED=!SELECTED! %APP_SERVICES%"
    ) else (
        call :is_service %%a && (set "SELECTED=!SELECTED! %%a") || call :warn "Unknown service: %%a"
    )
)
if defined SELECTED set "SELECTED=!SELECTED:~1!"
exit /b 0

:selection_has_app
:: errorlevel 0 if SELECTED contains core or chat
for %%s in (!SELECTED!) do (
    if /i "%%s"=="core" exit /b 0
    if /i "%%s"=="chat" exit /b 0
)
exit /b 1

:state
:: state <service> -> STATE (running, exited, ... or "not created") and HEALTH (healthy, starting,
:: unhealthy, or none when the container has no health check)
set "STATE=not created"
set "HEALTH=none"
for /f "tokens=1,2" %%a in ('docker inspect -f "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" chatty-%~1 2^>nul') do (
    set "STATE=%%a"
    set "HEALTH=%%b"
)
exit /b 0

:is_running
call :state %~1
if "!STATE!"=="running" exit /b 0
exit /b 1

:svc_info
:: svc_info <service> -> SVC_ADDR, SVC_DESC
set "SVC_ADDR="
set "SVC_DESC="
if "%~1"=="core" (
    set "SVC_ADDR=http://127.0.0.1:%CFG_CORE_API_PORT%"
    set "SVC_DESC=chatty-core API, Django"
)
if "%~1"=="chat" (
    set "SVC_ADDR=http://127.0.0.1:%CFG_CHAT_API_PORT%"
    set "SVC_DESC=chatty-chat API, FastAPI"
)
if "%~1"=="core-db" (
    set "SVC_ADDR=127.0.0.1:%CFG_CORE_DB_PORT%"
    set "SVC_DESC=Postgres, %CFG_CORE_DB_NAME%"
)
if "%~1"=="chat-db" (
    set "SVC_ADDR=127.0.0.1:%CFG_CHAT_DB_PORT%"
    set "SVC_DESC=Postgres, %CFG_CHAT_DB_NAME%"
)
if "%~1"=="redis" (
    set "SVC_ADDR=127.0.0.1:%CFG_REDIS_PORT%"
    set "SVC_DESC=Redis"
)
if "%~1"=="minio" (
    set "SVC_ADDR=http://127.0.0.1:%CFG_MINIO_CONSOLE_PORT%"
    set "SVC_DESC=MinIO console, API on %CFG_MINIO_API_PORT%"
)
if "%~1"=="kafka" (
    set "SVC_ADDR=127.0.0.1:%CFG_KAFKA_PORT%"
    set "SVC_DESC=Kafka"
)
exit /b 0

:print_state
call :state %~1
call :svc_info %~1
set "_name=%~1             "
set "_color=%C_DIM%"
set "_label=!STATE!"
if "!STATE!"=="running" (
    set "_color=%C_GREEN%"
    if "!HEALTH!"=="healthy" set "_label=healthy"
    if "!HEALTH!"=="starting" (
        set "_color=%C_YELLOW%"
        set "_label=starting"
    )
    if "!HEALTH!"=="unhealthy" (
        set "_color=%C_RED%"
        set "_label=unhealthy"
    )
)
if "!STATE!"=="exited" set "_color=%C_RED%"
if "!STATE!"=="restarting" set "_color=%C_YELLOW%"
set "_label=!_label!              "
set "_addr=!SVC_ADDR!                          "
echo     %C_BOLD%!_name:~0,9!%C_RESET% !_color!!_label:~0,12!%C_RESET% !_addr:~0,26! %C_DIM%!SVC_DESC!%C_RESET%
exit /b 0

:status_table
echo     %C_DIM%SERVICE   STATE        ADDRESS%C_RESET%
for %%s in (%ALL_SERVICES%) do call :print_state %%s
exit /b 0

:compose_up
:: compose_up "<services>" [--build] [--force-recreate]
set "_flags=-d --wait --wait-timeout 180"
if not "%~2"=="" set "_flags=!_flags! %~2"
if not "%~3"=="" set "_flags=!_flags! %~3"
docker compose up !_flags! %~1
exit /b %errorlevel%

:ensure_running
:: ensure_running <service> -> starts it after asking (or right away when INTERACTIVE=0)
call :is_running %~1 && exit /b 0
call :warn "%~1 is not running."
if not "%INTERACTIVE%"=="0" (
    call :confirm "Start %~1 now?"
    if "!CONFIRMED!"=="0" exit /b 1
)
call :info "Starting %~1 ..."
docker compose up -d --wait --wait-timeout 180 %~1
if errorlevel 1 (
    call :err "%~1 did not start. See: logs.bat %~1"
    exit /b 1
)
call :ok "%~1 is up."
exit /b 0

:show_problems
:: show_problems "<services>" -> prints the last log lines of every service that isn't running or
:: is unhealthy. errorlevel 1 if there was one.
set "_bad="
for %%s in (%~1) do (
    call :state %%s
    set "_isbad=0"
    if not "!STATE!"=="running" set "_isbad=1"
    if "!HEALTH!"=="unhealthy" set "_isbad=1"
    if "!_isbad!"=="1" set "_bad=!_bad! %%s"
)
if not defined _bad exit /b 0
for %%s in (!_bad!) do (
    call :state %%s
    echo.
    call :err "%%s: state !STATE!, health !HEALTH!. Last 30 log lines:"
    echo %C_DIM%
    docker compose logs --no-color --tail 30 %%s
    echo %C_RESET%
)
exit /b 1

:drop_missing_repos
:: Removes core/chat from SELECTED when their repo isn't cloned next to chatty-infra.
set "_kept="
for %%s in (!SELECTED!) do (
    set "_keep=1"
    if /i "%%s"=="core" if not exist "%CORE_DIR%\Dockerfile" set "_keep=0"
    if /i "%%s"=="chat" if not exist "%CHAT_DIR%\Dockerfile" set "_keep=0"
    if "!_keep!"=="1" (
        set "_kept=!_kept! %%s"
    ) else (
        call :warn "Skipping %%s: %WORKSPACE%\chatty-%%s not found."
        call :hint "Clone it with: git clone https://github.com/Chatty4/chatty-%%s.git %WORKSPACE%\chatty-%%s"
    )
)
set "SELECTED="
if defined _kept set "SELECTED=!_kept:~1!"
exit /b 0


:: =============================================================================================
:: Checks
:: =============================================================================================

:check_docker
where docker >nul 2>&1
if errorlevel 1 (
    call :err "Docker is not installed or not on PATH."
    call :hint "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
    exit /b 1
)
docker info >nul 2>&1
if not errorlevel 1 (
    call :ok "Docker is running."
    exit /b 0
)
call :warn "Docker is installed but not running."
call :find_docker_desktop
if not defined DOCKER_DESKTOP (
    call :hint "Start Docker Desktop and run this again."
    exit /b 1
)
if not "%INTERACTIVE%"=="0" (
    call :confirm "Start Docker Desktop now?"
    if "!CONFIRMED!"=="0" exit /b 1
)
start "" "!DOCKER_DESKTOP!"
call :info "Waiting for Docker, up to 2 minutes ..."
for /l %%i in (1,1,60) do (
    docker info >nul 2>&1 && goto :docker_ready
    call :sleep 2
)
call :err "Docker did not start in 2 minutes."
exit /b 1
:docker_ready
call :ok "Docker is running."
exit /b 0

:find_docker_desktop
:: Docker Desktop is per-user or per-machine; find it from docker.exe first.
set "DOCKER_DESKTOP="
set "_dexe="
for %%i in (docker.exe) do set "_dexe=%%~$PATH:i"
if defined _dexe (
    for %%i in ("!_dexe!\..\..\..") do set "_dhome=%%~fi"
    if exist "!_dhome!\Docker Desktop.exe" set "DOCKER_DESKTOP=!_dhome!\Docker Desktop.exe"
    if exist "!_dhome!\frontend\Docker Desktop.exe" set "DOCKER_DESKTOP=!_dhome!\frontend\Docker Desktop.exe"
)
if not defined DOCKER_DESKTOP if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" set "DOCKER_DESKTOP=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not defined DOCKER_DESKTOP if exist "%LOCALAPPDATA%\Programs\DockerDesktop\frontend\Docker Desktop.exe" set "DOCKER_DESKTOP=%LOCALAPPDATA%\Programs\DockerDesktop\frontend\Docker Desktop.exe"
exit /b 0

:check_env_files
if exist "%ROOT%\.env" (
    call :ok "chatty-infra\.env found."
) else (
    call :info "No chatty-infra\.env, using the values from .env.example."
)
for %%r in (core chat) do (
    if exist "%WORKSPACE%\chatty-%%r\.env.example" if not exist "%WORKSPACE%\chatty-%%r\.env" (
        call :info "chatty-%%r\.env not found. Docker does not need it, uvicorn outside Docker does."
        if not "%INTERACTIVE%"=="0" (
            call :confirm "Create chatty-%%r\.env from .env.example?"
            if "!CONFIRMED!"=="1" (
                copy "%WORKSPACE%\chatty-%%r\.env.example" "%WORKSPACE%\chatty-%%r\.env" >nul
                call :ok "chatty-%%r\.env created. Review the values before running it outside Docker."
            )
        )
    )
)
exit /b 0

:check_app_ports
:: For every app in SELECTED that isn't running yet: is its port already taken on the host?
for %%s in (!SELECTED!) do (
    set "_port="
    set "PORT_OWNER="
    if /i "%%s"=="core" set "_port=%CFG_CORE_API_PORT%"
    if /i "%%s"=="chat" set "_port=%CFG_CHAT_API_PORT%"
    if defined _port (
        call :is_running %%s || call :port_owner !_port!
        if defined PORT_OWNER (
            call :warn "Port !_port! for %%s is already used by !PORT_OWNER!."
            call :hint "Is uvicorn running locally? Stop it, or set CHAT_API_PORT / CORE_API_PORT in chatty-infra\.env"
            if not "%INTERACTIVE%"=="0" (
                call :confirm "Try to start anyway?"
                if "!CONFIRMED!"=="0" exit /b 1
            )
        )
    )
)
exit /b 0

:port_owner
:: port_owner <port> -> PORT_OWNER = "process.exe, PID n" if something listens on it, else empty
set "PORT_OWNER="
set "_pid="
for /f "tokens=5" %%p in ('netstat -ano -p tcp ^| findstr /c:":%~1 " ^| findstr LISTENING') do set "_pid=%%p"
if not defined _pid exit /b 0
set "PORT_OWNER=PID !_pid!"
for /f "tokens=1 delims=," %%n in ('tasklist /fi "pid eq !_pid!" /fo csv /nh 2^>nul') do set "PORT_OWNER=%%~n, PID !_pid!"
exit /b 0

:core_has_user_model
:: chatty-core's CLAUDE.md: never migrate core_db before the custom User model exists.
findstr /c:"AUTH_USER_MODEL" "%CORE_DIR%\config\settings.py" >nul 2>&1
exit /b %errorlevel%


:: =============================================================================================
:: HTTP and app health
:: =============================================================================================

:http_code
set "HTTP_CODE=000"
for /f %%c in ('curl.exe -s -o nul -w "%%{http_code}" --max-time 3 "%~1" 2^>nul') do set "HTTP_CODE=%%c"
exit /b 0

:wait_http
:: wait_http <url> <seconds> -> HTTP_CODE, errorlevel 0 once it answers 200
set "HTTP_CODE=000"
set /a "_tries=%~2/2"
for /l %%i in (1,1,!_tries!) do (
    call :http_code "%~1"
    if "!HTTP_CODE!"=="200" exit /b 0
    call :sleep 2
)
exit /b 1

:check_apps
:: check_apps "<services>" -> waits for /health of every running app in the list
for %%s in (%~1) do (
    if /i "%%s"=="core" call :check_app core "http://127.0.0.1:%CFG_CORE_API_PORT%/health"
    if /i "%%s"=="chat" call :check_app chat "http://127.0.0.1:%CFG_CHAT_API_PORT%/health"
)
exit /b 0

:check_app
call :is_running %~1 || exit /b 0
call :wait_http "%~2" 60
if "!HTTP_CODE!"=="200" (
    call :ok "%~1 answers on %~2"
) else if "!HTTP_CODE!"=="503" (
    call :warn "%~1 is up but degraded: %~2 returned 503. A database or Redis is down."
) else (
    call :warn "%~1 did not answer on %~2, got HTTP !HTTP_CODE!. See: logs.bat %~1"
)
exit /b 0


:: =============================================================================================
:: Backups and misc
:: =============================================================================================

:timestamp
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmmss"') do set "STAMP=%%t"
exit /b 0

:backup_db
:: backup_db <db service> <user> <database> <folder> -> BACKUP_OK=1 or 0, BACKUP_FILE
set "BACKUP_OK=0"
set "BACKUP_FILE=%~4\%~3.sql"
call :is_running %~1
if errorlevel 1 (
    call :warn "%~1 is not running, so %~3 cannot be backed up."
    exit /b 1
)
if not exist "%~4" mkdir "%~4"
docker compose exec -T %~1 pg_dump -U %~2 -d %~3 --clean --if-exists > "!BACKUP_FILE!"
if errorlevel 1 (
    call :warn "pg_dump of %~3 failed."
    exit /b 1
)
for %%f in ("!BACKUP_FILE!") do if %%~zf lss 1 (
    call :warn "Backup of %~3 is empty."
    exit /b 1
)
set "BACKUP_OK=1"
call :ok "%~3 saved to !BACKUP_FILE!"
exit /b 0

:sleep
:: sleep <seconds>. ping instead of timeout: timeout fails when input is redirected.
set /a "_s=%~1+1"
ping -n !_s! 127.0.0.1 >nul
exit /b 0
