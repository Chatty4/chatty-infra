@echo off
:: Database migrations for chatty-core (Django) and chatty-chat (Alembic), run inside the containers.
::
::   migrate.bat                          menu
::   migrate.bat <core|chat|all> <action>
::
:: Actions:
::   status     what is applied and what is pending
::   apply      apply pending migrations
::   make       create a new migration from model changes; read it before applying it
::   check      fail if a model change has no migration, as CI does
::   rollback   undo migrations, asks what to undo
::
:: chatty-core refuses "apply" while the custom User model doesn't exist (chatty-core CLAUDE.md).
:: Add --force to apply anyway.
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Migrations"

set "TARGET=%~1"
set "ACTION=%~2"
set "FORCE=0"
for %%a in (%*) do if /i "%%a"=="--force" set "FORCE=1"
if defined TARGET (set "INTERACTIVE=0") else set "INTERACTIVE=1"
set "_r=0"

call "%LIB%" :check_docker || goto :failed
if "%INTERACTIVE%"=="0" goto :run

echo   Which service?
echo.
call "%LIB%" :menu_item 1 "chatty-core" "Django, core_db"
call "%LIB%" :menu_item 2 "chatty-chat" "Alembic, chat_db"
call "%LIB%" :menu_item 3 "Both"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 123Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="1" set "TARGET=core"
if "!CH!"=="2" set "TARGET=chat"
if "!CH!"=="3" set "TARGET=all"
if not defined TARGET goto :cancel

echo.
echo   What do you want to do?
echo.
call "%LIB%" :menu_item 1 "Status" "applied and pending migrations"
call "%LIB%" :menu_item 2 "Apply" "apply pending migrations"
call "%LIB%" :menu_item 3 "Make" "create a migration from model changes"
call "%LIB%" :menu_item 4 "Check" "fail if a model change has no migration, like CI"
call "%LIB%" :menu_item 5 "Rollback" "undo migrations"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 12345Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="1" set "ACTION=status"
if "!CH!"=="2" set "ACTION=apply"
if "!CH!"=="3" set "ACTION=make"
if "!CH!"=="4" set "ACTION=check"
if "!CH!"=="5" set "ACTION=rollback"
if not defined ACTION goto :cancel

:run
if not defined ACTION set "ACTION=status"
set "TARGETS=!TARGET!"
if /i "!TARGET!"=="all" set "TARGETS=core chat"
for %%t in (!TARGETS!) do (
    if /i not "%%t"=="core" if /i not "%%t"=="chat" (
        call "%LIB%" :err "Unknown service: %%t. Use core, chat or all."
        goto :failed
    )
)
for %%a in (status apply make check rollback) do if /i "!ACTION!"=="%%a" goto :action_ok
call "%LIB%" :err "Unknown action: !ACTION!. Use status, apply, make, check or rollback."
goto :failed
:action_ok

for %%t in (!TARGETS!) do (
    echo.
    echo %C_BOLD%%C_CYAN%  chatty-%%t: !ACTION!%C_RESET%
    call :%%t_!ACTION!
)
goto :summary


:: =============================================================================================
:: chatty-core: Django
:: =============================================================================================

:core_status
call "%LIB%" :ensure_running core || (call :result core skip "not running" & exit /b 0)
docker compose exec core python manage.py showmigrations
call :result_from_errorlevel core "status shown"
call "%LIB%" :hint "[X] = applied, [ ] = pending"
exit /b 0

:core_apply
call "%LIB%" :core_has_user_model
if errorlevel 1 if "%FORCE%"=="0" (
    call "%LIB%" :warn "chatty-core has no custom User model yet: AUTH_USER_MODEL is not set."
    call "%LIB%" :hint "Migrating now creates Django's auth_user table, and switching to users.User later"
    call "%LIB%" :hint "means resetting core_db. chatty-core's CLAUDE.md says to wait."
    if "%INTERACTIVE%"=="0" (
        call "%LIB%" :hint "Run with --force to migrate anyway."
        call :result core skip "no User model yet"
        exit /b 0
    )
    call "%LIB%" :type_to_confirm MIGRATE "Migrate core_db anyway?"
    if "!CONFIRMED!"=="0" (
        call :result core skip "no User model yet"
        exit /b 0
    )
)
call "%LIB%" :ensure_running core || (call :result core skip "not running" & exit /b 0)
docker compose exec core python manage.py migrate
call :result_from_errorlevel core "migrated"
exit /b 0

:core_make
call "%LIB%" :ensure_running core || (call :result core skip "not running" & exit /b 0)
set "APP_LABEL="
if "%INTERACTIVE%"=="1" set /p "APP_LABEL=  App label, e.g. users. Enter for all apps: "
docker compose exec core python manage.py makemigrations !APP_LABEL!
call :result_from_errorlevel core "makemigrations done"
call "%LIB%" :hint "Read the new files in chatty-core\<app>\migrations before applying them."
exit /b 0

:core_check
call "%LIB%" :ensure_running core || (call :result core skip "not running" & exit /b 0)
docker compose exec core python manage.py makemigrations --check --dry-run
call :result_from_errorlevel core "no missing migrations"
exit /b 0

:core_rollback
call "%LIB%" :ensure_running core || (call :result core skip "not running" & exit /b 0)
if "%INTERACTIVE%"=="0" (
    call "%LIB%" :warn "Rollback needs answers; run migrate.bat without arguments."
    call :result core skip "needs the menu"
    exit /b 0
)
docker compose exec core python manage.py showmigrations
set "APP_LABEL="
set "TARGET_MIG="
set /p "APP_LABEL=  App to roll back, e.g. users: "
if not defined APP_LABEL (call :result core skip "cancelled" & exit /b 0)
set /p "TARGET_MIG=  Go back to which migration? e.g. 0003, or zero for none: "
if not defined TARGET_MIG (call :result core skip "cancelled" & exit /b 0)
call "%LIB%" :confirm "Roll !APP_LABEL! back to !TARGET_MIG!? Data in dropped tables or columns is lost."
if "!CONFIRMED!"=="0" (call :result core skip "cancelled" & exit /b 0)
docker compose exec core python manage.py migrate !APP_LABEL! !TARGET_MIG!
call :result_from_errorlevel core "rolled back !APP_LABEL! to !TARGET_MIG!"
exit /b 0


:: =============================================================================================
:: chatty-chat: Alembic
:: =============================================================================================

:chat_status
call "%LIB%" :ensure_running chat || (call :result chat skip "not running" & exit /b 0)
echo   %C_BOLD%Applied:%C_RESET%
docker compose exec chat alembic current
echo   %C_BOLD%Latest:%C_RESET%
docker compose exec chat alembic heads
echo   %C_BOLD%History:%C_RESET%
docker compose exec chat alembic history --indicate-current
call :result_from_errorlevel chat "status shown"
exit /b 0

:chat_apply
call "%LIB%" :ensure_running chat || (call :result chat skip "not running" & exit /b 0)
docker compose exec chat alembic upgrade head
call :result_from_errorlevel chat "migrated to head"
exit /b 0

:chat_make
call "%LIB%" :ensure_running chat || (call :result chat skip "not running" & exit /b 0)
set "MSG="
if "%INTERACTIVE%"=="1" set /p "MSG=  Describe the change, e.g. add messages table: "
if not defined MSG (
    call "%LIB%" :warn "A migration needs a description."
    call :result chat skip "cancelled"
    exit /b 0
)
set "MSG=!MSG:"=!"
:: Alembic won't create the first revision when alembic\versions is missing, and git doesn't keep
:: empty folders.
if not exist "%CHAT_DIR%\alembic\versions" mkdir "%CHAT_DIR%\alembic\versions"
docker compose exec chat alembic revision --autogenerate -m "!MSG!"
call :result_from_errorlevel chat "revision created"
call "%LIB%" :hint "Read the new file in chatty-chat\alembic\versions before applying it. Autogenerate misses things."
exit /b 0

:chat_check
call "%LIB%" :ensure_running chat || (call :result chat skip "not running" & exit /b 0)
docker compose exec chat alembic check
call :result_from_errorlevel chat "no missing migrations"
exit /b 0

:chat_rollback
call "%LIB%" :ensure_running chat || (call :result chat skip "not running" & exit /b 0)
if "%INTERACTIVE%"=="0" (
    call "%LIB%" :warn "Rollback needs answers; run migrate.bat without arguments."
    call :result chat skip "needs the menu"
    exit /b 0
)
echo   %C_BOLD%Applied:%C_RESET%
docker compose exec chat alembic current
call "%LIB%" :confirm "Undo the last chat migration? Data in dropped tables or columns is lost."
if "!CONFIRMED!"=="0" (call :result chat skip "cancelled" & exit /b 0)
docker compose exec chat alembic downgrade -1
call :result_from_errorlevel chat "rolled back one revision"
exit /b 0


:: =============================================================================================
:: Results
:: =============================================================================================

:result_from_errorlevel
:: result_from_errorlevel <service> "<text when it worked>"
if errorlevel 1 (
    call :result %~1 fail "see the output above"
) else (
    call :result %~1 ok "%~2"
)
exit /b 0

:result
:: result <service> <ok|fail|skip> "<text>"
set /a "_r+=1"
set "RESULT_!_r!=%~1|%~2|%~3"
exit /b 0

:summary
echo.
echo %C_BOLD%  Summary%C_RESET%
set "ANY_FAIL=0"
for /l %%i in (1,1,!_r!) do (
    for /f "tokens=1,2,* delims=|" %%a in ("!RESULT_%%i!") do (
        set "_svc=%%a      "
        if "%%b"=="ok" echo   %C_GREEN%[ OK ]%C_RESET% !_svc:~0,6! %%c
        if "%%b"=="skip" echo   %C_YELLOW%[SKIP]%C_RESET% !_svc:~0,6! %%c
        if "%%b"=="fail" (
            echo   %C_RED%[FAIL]%C_RESET% !_svc:~0,6! %%c
            set "ANY_FAIL=1"
        )
    )
)
call "%LIB%" :finish
exit /b !ANY_FAIL!

:cancel
echo.
call "%LIB%" :info "Nothing done."
call "%LIB%" :finish
exit /b 0

:failed
call "%LIB%" :finish
exit /b 1
