@echo off
:: Runs lint and tests inside the containers, the same checks as CI.
::
::   test.bat                         menu
::   test.bat <core|chat|all> [mode]
::
:: Modes:
::   ci       ruff check, ruff format --check, pre-test checks, pytest (default)
::   tests    pytest only
::   lint     ruff check and ruff format --check
::   fix      ruff check --fix, then ruff format. This changes your files
::
:: Anything after the mode goes to pytest, e.g.:  test.bat chat tests -m "not integration"
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Tests and lint"

set "TARGET=%~1"
set "MODE=%~2"
set "PYTEST_ARGS="
if not "%~2"=="" (
    for /f "tokens=2,* delims= " %%a in ("%*") do set "PYTEST_ARGS=%%b"
)
if defined TARGET (set "INTERACTIVE=0") else set "INTERACTIVE=1"
if not defined MODE set "MODE=ci"
set "_r=0"

call "%LIB%" :check_docker || goto :failed
if "%INTERACTIVE%"=="0" goto :run

echo   Which repo?
echo.
call "%LIB%" :menu_item 1 "chatty-core"
call "%LIB%" :menu_item 2 "chatty-chat"
call "%LIB%" :menu_item 3 "Both"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 123Q /n /m "  Choose: "
set "CH=!errorlevel!"
set "TARGET="
if "!CH!"=="1" set "TARGET=core"
if "!CH!"=="2" set "TARGET=chat"
if "!CH!"=="3" set "TARGET=all"
if not defined TARGET goto :cancel
echo.
echo   What?
echo.
call "%LIB%" :menu_item 1 "Same as CI" "ruff check, ruff format --check, pre-test checks, pytest"
call "%LIB%" :menu_item 2 "Tests only" "pytest"
call "%LIB%" :menu_item 3 "Lint only" "ruff check, ruff format --check"
call "%LIB%" :menu_item 4 "Fix lint" "ruff check --fix, ruff format. Changes your files"
call "%LIB%" :menu_item Q "Quit"
echo.
choice /c 1234Q /n /m "  Choose: "
set "CH=!errorlevel!"
if "!CH!"=="5" goto :cancel
for /f "tokens=%CH%" %%m in ("ci tests lint fix") do set "MODE=%%m"

:run
set "TARGETS=!TARGET!"
if /i "!TARGET!"=="all" set "TARGETS=core chat"
for %%t in (!TARGETS!) do (
    if /i not "%%t"=="core" if /i not "%%t"=="chat" (
        call "%LIB%" :err "Unknown repo: %%t. Use core, chat or all."
        goto :failed
    )
)

for %%t in (!TARGETS!) do (
    echo.
    echo %C_BOLD%%C_CYAN%  chatty-%%t: !MODE!%C_RESET%
    call "%LIB%" :ensure_running %%t
    if errorlevel 1 (
        call :result %%t skip "not running"
    ) else (
        call :run_%%t
    )
)
goto :summary


:run_core
if "!MODE!"=="fix" (
    call :check core "ruff check --fix" ruff check --fix .
    call :check core "ruff format" ruff format .
    exit /b 0
)
if "!MODE!"=="ci" set "_lint=1"
if "!MODE!"=="lint" set "_lint=1"
if defined _lint (
    call :check core "ruff check" ruff check .
    call :check core "ruff format --check" ruff format --check .
)
set "_lint="
if "!MODE!"=="ci" (
    call :check core "manage.py check" python manage.py check
    call :check core "missing migrations" python manage.py makemigrations --check --dry-run
)
if "!MODE!"=="ci" call :check core "pytest" pytest !PYTEST_ARGS!
if "!MODE!"=="tests" call :check core "pytest" pytest !PYTEST_ARGS!
exit /b 0

:run_chat
if "!MODE!"=="fix" (
    call :check chat "ruff check --fix" ruff check --fix .
    call :check chat "ruff format" ruff format .
    exit /b 0
)
if "!MODE!"=="ci" set "_lint=1"
if "!MODE!"=="lint" set "_lint=1"
if defined _lint (
    call :check chat "ruff check" ruff check .
    call :check chat "ruff format --check" ruff format --check .
)
set "_lint="
:: CI also runs alembic upgrade head and alembic check on an empty database; your dev database may be
:: behind on purpose, so that check lives in migrate.bat instead.
if "!MODE!"=="ci" call :check chat "pytest" pytest !PYTEST_ARGS!
if "!MODE!"=="tests" call :check chat "pytest" pytest !PYTEST_ARGS!
exit /b 0

:check
:: check <service> "<label>" <command...>
set "_svc=%~1"
set "_label=%~2"
shift
shift
set "_cmd="
:check_args
if "%~1"=="" goto :check_run
set "_cmd=!_cmd! %1"
shift
goto :check_args
:check_run
echo.
echo   %C_DIM%$!_cmd!%C_RESET%
docker compose exec !_svc!!_cmd!
if errorlevel 1 (
    call :result !_svc! fail "!_label!"
) else (
    call :result !_svc! ok "!_label!"
)
exit /b 0

:result
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
if "!ANY_FAIL!"=="1" if not "!MODE!"=="fix" call "%LIB%" :hint "Lint failures: test.bat, then Fix lint, fixes most of them."
call "%LIB%" :finish
exit /b !ANY_FAIL!

:cancel
echo.
call "%LIB%" :info "Nothing run."
call "%LIB%" :finish
exit /b 0

:failed
call "%LIB%" :finish
exit /b 1
