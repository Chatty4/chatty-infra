@echo off
:: First-time setup on a new machine, and safe to run again any time.
::
::   1. Make an empty folder, e.g. C:\chatty, and clone chatty-infra into it:
::        git clone https://github.com/Chatty4/chatty-infra.git C:\chatty\chatty-infra
::   2. Run C:\chatty\chatty-infra\setup.bat
::
:: It clones the other repos next to chatty-infra on the dev branch, creates every .env from its
:: .env.example with matching secrets, creates the JWT and VAPID key pairs once, and can create
:: the Python virtualenvs and start the stack. Last, it starts Kafka and creates the chat.events
:: topic, then starts MinIO and creates the bucket chatty with a user for core and chat.
:: It never overwrites a .env value you have already set, and never touches a repo with changes.
::
::   setup.bat            asks at every step
::   setup.bat --yes      clone what's missing, create the .env files, the Kafka topic and the MinIO
::                        bucket, no questions; skips pulls, virtualenvs and starting the stack
setlocal EnableDelayedExpansion
call "%~dp0scripts\lib.bat" :init || exit /b 1
call "%LIB%" :title "Chatty - Setup"

if /i "%~1"=="--yes" (set "INTERACTIVE=0") else set "INTERACTIVE=1"
set "BRANCH=dev"
:: chatty-infra is cloned by hand first; everything else comes from here.
set "REPOS=chatty-core chatty-chat chatty-web .github"
set "WARNINGS=0"

:: Clone the others the same way chatty-infra was cloned: same owner, HTTPS or SSH.
set "INFRA_URL="
for /f "delims=" %%u in ('git -C "%ROOT%" remote get-url origin 2^>nul') do set "INFRA_URL=%%u"
set "REMOTE_BASE=https://github.com/Chatty4/"
if defined INFRA_URL (
    if /i "!INFRA_URL:~-16!"=="chatty-infra.git" (
        set "REMOTE_BASE=!INFRA_URL:~0,-16!"
    ) else if /i "!INFRA_URL:~-12!"=="chatty-infra" (
        set "REMOTE_BASE=!INFRA_URL:~0,-12!"
    )
)

echo   Workspace: %C_BOLD%%WORKSPACE%%C_RESET%
echo   Clone from: %C_BOLD%!REMOTE_BASE!%C_RESET%   branch: %C_BOLD%%BRANCH%%C_RESET%
echo.

:: ---- 1. Tools -------------------------------------------------------------------------------
call "%LIB%" :step 1 9 "Checking tools"
where git >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :err "git is not installed. Get it from https://git-scm.com/download/win"
    goto :failed
)
for /f "tokens=3" %%v in ('git --version') do call "%LIB%" :ok "git %%v"

set "PY="
py -3.14 -c "import sys" >nul 2>&1 && set "PY=py -3.14"
if not defined PY (
    python -c "import sys; sys.exit(0 if sys.version_info[:2] == (3, 14) else 1)" >nul 2>&1 && set "PY=python"
)
if defined PY (
    call "%LIB%" :ok "Python 3.14, as: !PY!"
) else (
    call "%LIB%" :warn "Python 3.14 not found. Docker works without it; local virtualenvs need it."
    call "%LIB%" :hint "Install it from https://www.python.org/downloads/ or: winget install Python.Python.3.14"
    set "WARNINGS=1"
)

where docker >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :warn "Docker is not installed. The stack runs in Docker Desktop."
    call "%LIB%" :hint "https://www.docker.com/products/docker-desktop/"
    set "WARNINGS=1"
) else (
    call "%LIB%" :ok "Docker CLI found."
)

:: ---- 2. Repos -------------------------------------------------------------------------------
call "%LIB%" :step 2 9 "Cloning the repos"
for %%r in (%REPOS%) do call :repo %%r

:: ---- 3. .env files --------------------------------------------------------------------------
call "%LIB%" :step 3 9 "Creating .env files"
call :env_file "%ROOT%" chatty-infra
call :env_file "%CORE_DIR%" chatty-core
call :env_file "%CHAT_DIR%" chatty-chat
call :env_file "%WORKSPACE%\chatty-web" chatty-web

:: One CORE_SERVICE_TOKEN for chatty-infra (Docker) and chatty-chat (local runs), and a real Django
:: SECRET_KEY for chatty-core in both. Values that are already set are kept and reused.
call :random_hex 32
set "NEW_TOKEN=!HEX!"
call :random_hex 32
set "NEW_SECRET=!HEX!"
if exist "%ROOT%\.env" (
    call :set_env "%ROOT%\.env" chatty-infra CORE_SERVICE_TOKEN !NEW_TOKEN!
    call :set_env "%ROOT%\.env" chatty-infra CORE_SECRET_KEY !NEW_SECRET!
    call "%LIB%" :load_env "%ROOT%\.env"
    if defined CFG_CORE_SERVICE_TOKEN if not "!CFG_CORE_SERVICE_TOKEN!"=="change-me" set "NEW_TOKEN=!CFG_CORE_SERVICE_TOKEN!"
    if defined CFG_CORE_SECRET_KEY if not "!CFG_CORE_SECRET_KEY!"=="dev-only-not-secret" set "NEW_SECRET=!CFG_CORE_SECRET_KEY!"
)
if exist "%CHAT_DIR%\.env" call :set_env "%CHAT_DIR%\.env" chatty-chat CORE_SERVICE_TOKEN !NEW_TOKEN!
if exist "%CORE_DIR%\.env" call :set_env "%CORE_DIR%\.env" chatty-core SECRET_KEY !NEW_SECRET!
call :vapid_keys
call :web_vapid_key
call :minio_secrets

:: ---- 4. JWT keys ----------------------------------------------------------------------------
call "%LIB%" :step 4 9 "JWT keys"
call :jwt_keys

:: ---- 5. VS Code workspace -------------------------------------------------------------------
call "%LIB%" :step 5 9 "VS Code workspace"
set "WS_FILE=%WORKSPACE%\chatty.code-workspace"
if exist "%WS_FILE%" (
    call "%LIB%" :ok "chatty.code-workspace already exists."
) else (
    > "%WS_FILE%" (
        echo {
        echo     "folders": [
        echo         { "name": "chatty-infra", "path": "chatty-infra" },
        echo         { "name": "chatty-core", "path": "chatty-core" },
        echo         { "name": "chatty-chat", "path": "chatty-chat" },
        echo         { "name": "chatty-web", "path": "chatty-web" }
        echo     ],
        echo     "settings": {
        echo         "python.defaultInterpreterPath": "${workspaceFolder}/chatty-chat/.venv/Scripts/python.exe"
        echo     }
        echo }
    )
    call "%LIB%" :ok "Created chatty.code-workspace next to the repos."
)

:: ---- 6. Virtualenvs and packages ------------------------------------------------------------
call "%LIB%" :step 6 9 "Local virtualenvs and packages"
if "%INTERACTIVE%"=="0" (
    call "%LIB%" :info "Skipped with --yes. Run setup.bat again without it to create them."
) else (
    call "%LIB%" :hint "Docker has its own packages. A local .venv is for your editor and for running outside Docker."
    call :venv chatty-core
    call :venv chatty-chat
    call :web_packages
)

:: ---- 7. Start -------------------------------------------------------------------------------
call "%LIB%" :step 7 9 "Start the stack"
if "%INTERACTIVE%"=="0" (
    call "%LIB%" :info "Skipped with --yes. Run start.bat when you're ready."
) else (
    where docker >nul 2>&1
    if errorlevel 1 (
        call "%LIB%" :info "Skipped: Docker is not installed."
    ) else (
        call "%LIB%" :confirm "Start everything in Docker now? The first run builds the images, a few minutes."
        if "!CONFIRMED!"=="1" (
            set "CHATTY_NO_PAUSE=1"
            call "%ROOT%\start.bat" all
        )
    )
)

:: ---- 8. Kafka topic -------------------------------------------------------------------------
:: Runs even when step 7 was skipped: it starts Kafka on its own, so the topic always exists.
call "%LIB%" :step 8 9 "Kafka topic"
call "%LIB%" :create_kafka_topic || set "WARNINGS=1"

:: ---- 9. MinIO bucket ------------------------------------------------------------------------
:: Like the topic: it starts MinIO on its own, so the bucket and the service users always exist.
call "%LIB%" :step 9 9 "MinIO bucket"
call "%LIB%" :create_minio_bucket || set "WARNINGS=1"

echo.
if "!WARNINGS!"=="1" (
    call "%LIB%" :warn "Setup finished with warnings, see above."
) else (
    call "%LIB%" :ok "Setup finished."
)
call "%LIB%" :hint "Next: double-click chatty.bat for the menu, or open chatty.code-workspace in VS Code."
call "%LIB%" :finish
exit /b 0

:failed
echo.
call "%LIB%" :err "Setup stopped. Fix the problem above and run setup.bat again."
call "%LIB%" :finish
exit /b 1


:: =============================================================================================

:repo
:: repo <name>: clone it on BRANCH, or report on the existing clone and offer to pull
set "_dir=%WORKSPACE%\%~1"
set "_url=!REMOTE_BASE!%~1.git"
if exist "!_dir!\.git" goto :repo_existing
if exist "!_dir!" (
    call "%LIB%" :warn "%~1: the folder exists but is not a git repo. Left alone."
    set "WARNINGS=1"
    exit /b 0
)
call "%LIB%" :info "%~1: cloning !_url! ..."
set "_b="
git ls-remote --exit-code --heads "!_url!" %BRANCH% >nul 2>&1 && set "_b=-b %BRANCH%"
git clone --quiet !_b! "!_url!" "!_dir!"
if errorlevel 1 (
    call "%LIB%" :err "%~1: clone failed."
    call "%LIB%" :hint "Private repo? Log in first: gh auth login, or set up an SSH key."
    set "WARNINGS=1"
    exit /b 0
)
for /f "delims=" %%b in ('git -C "!_dir!" branch --show-current') do set "_cur=%%b"
call "%LIB%" :ok "%~1: cloned, on !_cur!."
exit /b 0

:repo_existing
set "_cur=?"
set "_changes=0"
for /f "delims=" %%b in ('git -C "!_dir!" branch --show-current 2^>nul') do set "_cur=%%b"
for /f %%c in ('git -C "!_dir!" status --porcelain 2^>nul ^| find /c /v ""') do set "_changes=%%c"
if not "!_changes!"=="0" (
    call "%LIB%" :ok "%~1: already cloned, on !_cur!, !_changes! uncommitted files. Not touched."
    exit /b 0
)
call "%LIB%" :ok "%~1: already cloned, on !_cur!, clean."
if "%INTERACTIVE%"=="0" exit /b 0
git -C "!_dir!" rev-parse --abbrev-ref @{u} >nul 2>&1 || exit /b 0
call "%LIB%" :confirm "Pull the latest !_cur! for %~1?"
if "!CONFIRMED!"=="0" exit /b 0
git -C "!_dir!" pull --ff-only --quiet
if errorlevel 1 (
    call "%LIB%" :warn "%~1: pull failed. The branch has diverged; merge or rebase it yourself."
    set "WARNINGS=1"
) else (
    call "%LIB%" :ok "%~1: up to date."
)
exit /b 0

:env_file
:: env_file <repo dir> <name>: create .env from .env.example if it doesn't exist
if not exist "%~1\.env.example" exit /b 0
if exist "%~1\.env" (
    call "%LIB%" :ok "%~2\.env already exists, kept."
    exit /b 0
)
copy "%~1\.env.example" "%~1\.env" >nul
call "%LIB%" :ok "%~2\.env created from .env.example."
exit /b 0

:set_env
:: set_env <file> <repo name> <KEY> <value>: replaces the value only if it is still a placeholder
set "_res="
for /f %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\set-env-value.ps1" -Path "%~1" -Key %~3 -Value %~4') do set "_res=%%r"
if "!_res!"=="set" (
    call "%LIB%" :ok "%~2\.env: generated %~3."
) else if "!_res!"=="kept" (
    call "%LIB%" :ok "%~2\.env: %~3 already set, kept."
) else (
    call "%LIB%" :warn "%~2\.env: could not set %~3."
    set "WARNINGS=1"
)
exit /b 0

:vapid_keys
:: One VAPID key pair for Web Push (D-13) in chatty-chat\.env, made once: a new pair breaks every
:: browser subscription. The push worker signs with the private half; chatty-web needs the public one.
if not exist "%CHAT_DIR%\.env" exit /b 0
:: A .env made before the push worker has no VAPID lines, and set_env only fills a line that exists.
for %%k in (VAPID_PRIVATE_KEY VAPID_PUBLIC_KEY) do (
    findstr /b /c:"%%k=" "%CHAT_DIR%\.env" >nul || (echo.& echo %%k=)>>"%CHAT_DIR%\.env"
)
set "_priv="
set "_pub="
for /f "tokens=1,2" %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\vapid-keys.ps1"') do (
    set "_priv=%%a"
    set "_pub=%%b"
)
if not defined _pub (
    call "%LIB%" :warn "chatty-chat\.env: could not create the VAPID keys. The push worker won't start."
    set "WARNINGS=1"
    exit /b 0
)
call :set_env "%CHAT_DIR%\.env" chatty-chat VAPID_PRIVATE_KEY !_priv!
:: The public half only goes with its own private half, so a kept private key keeps its public key.
if "!_res!"=="set" call :set_env "%CHAT_DIR%\.env" chatty-chat VAPID_PUBLIC_KEY !_pub!
exit /b 0

:web_vapid_key
:: chatty-web's VITE_VAPID_PUBLIC_KEY is copied from chatty-chat\.env, so it always matches the key
:: the push worker signs with. A different key makes every push fail with 403.
set "_web=%WORKSPACE%\chatty-web\.env"
if not exist "!_web!" exit /b 0
if not exist "%CHAT_DIR%\.env" exit /b 0
set "_pub="
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"VAPID_PUBLIC_KEY=" "%CHAT_DIR%\.env"') do set "_pub=%%b"
if not defined _pub exit /b 0
:: A .env made before push notifications has no line for the key, and set_env only fills a line that exists.
findstr /b /c:"VITE_VAPID_PUBLIC_KEY=" "!_web!" >nul || (echo.& echo VITE_VAPID_PUBLIC_KEY=)>>"!_web!"
call :set_env "!_web!" chatty-web VITE_VAPID_PUBLIC_KEY !_pub!
if not "!_res!"=="kept" exit /b 0
set "_webpub="
for /f "tokens=1,* delims==" %%a in ('findstr /b /c:"VITE_VAPID_PUBLIC_KEY=" "!_web!"') do set "_webpub=%%b"
if not "!_webpub!"=="!_pub!" (
    call "%LIB%" :warn "chatty-web\.env: VITE_VAPID_PUBLIC_KEY differs from chatty-chat's VAPID_PUBLIC_KEY. Pushes will fail with 403."
    set "WARNINGS=1"
)
exit /b 0

:minio_secrets
:: A random secret for each service's MinIO user, in chatty-infra\.env (D-14). Kept once set: the
:: MinIO step sets the user's secret from .env every time it runs, so the two always match.
if not exist "%ROOT%\.env" exit /b 0
:: A .env made before files has no MinIO lines, and set_env only fills a line that exists. The access
:: keys need no line: .env.example and docker-compose.yml both default to chatty-core and chatty-chat.
for %%k in (CORE_MINIO_SECRET_KEY CHAT_MINIO_SECRET_KEY) do (
    findstr /b /c:"%%k=" "%ROOT%\.env" >nul || (echo.& echo %%k=)>>"%ROOT%\.env"
    call :random_hex 24
    call :set_env "%ROOT%\.env" chatty-infra %%k !HEX!
)
call "%LIB%" :load_env "%ROOT%\.env"
:: Core and chat run outside Docker too (local uvicorn and pytest), and then read MINIO_SECRET_KEY from
:: their own .env. chatty-infra\.env is the source, because the MinIO step sets the users from it, so
:: the copies are overwritten every time and can't drift.
call :copy_minio_secret "%CORE_DIR%" chatty-core "!CFG_CORE_MINIO_SECRET_KEY!"
call :copy_minio_secret "%CHAT_DIR%" chatty-chat "!CFG_CHAT_MINIO_SECRET_KEY!"
exit /b 0

:copy_minio_secret
:: copy_minio_secret <repo dir> <repo name> <secret>: MINIO_SECRET_KEY=<secret> in that repo's .env
if not exist "%~1\.env" exit /b 0
if "%~3"=="" exit /b 0
findstr /b /c:"MINIO_SECRET_KEY=" "%~1\.env" >nul || (echo.& echo MINIO_SECRET_KEY=)>>"%~1\.env"
set "_res="
for /f %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\set-env-value.ps1" -Path "%~1\.env" -Key MINIO_SECRET_KEY -Value %~3 -Force') do set "_res=%%r"
if "!_res!"=="set" (
    call "%LIB%" :ok "%~2\.env: MINIO_SECRET_KEY copied from chatty-infra\.env."
) else if "!_res!"=="kept" (
    call "%LIB%" :ok "%~2\.env: MINIO_SECRET_KEY already matches chatty-infra\.env."
) else (
    call "%LIB%" :warn "%~2\.env: could not copy MINIO_SECRET_KEY."
    set "WARNINGS=1"
)
exit /b 0

:jwt_keys
:: One key pair per developer in chatty-core\keys: core signs with the private key, chat gets the
:: public one. Never regenerated when it exists: a new pair logs everyone out.
set "_keys=%CORE_DIR%\keys"
if not exist "%CORE_DIR%" (
    call "%LIB%" :warn "chatty-core is not cloned, skipping the JWT keys."
    set "WARNINGS=1"
    exit /b 0
)
where docker >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :warn "Docker is needed for the JWT keys. Install it and run setup.bat again."
    set "WARNINGS=1"
    exit /b 0
)
:: Starting chat before the keys existed makes Docker Desktop create an empty folder named
:: jwt_public.pem in their place. Remove those, so they don't count as keys below.
for %%f in (jwt_private.pem jwt_public.pem) do if exist "!_keys!\%%f\" rmdir "!_keys!\%%f" 2>nul
set "_have=0"
if exist "!_keys!\jwt_private.pem" if exist "!_keys!\jwt_public.pem" set "_have=1"
if "!_have!"=="1" (
    call "%LIB%" :ok "chatty-core\keys: JWT keys already exist, kept."
) else (
    if not exist "!_keys!" mkdir "!_keys!"
    docker run --rm -v "!_keys!:/keys" alpine/openssl:3.5.9 genrsa -out /keys/jwt_private.pem 2048 >nul 2>&1
    docker run --rm -v "!_keys!:/keys" alpine/openssl:3.5.9 rsa -in /keys/jwt_private.pem -pubout -out /keys/jwt_public.pem >nul 2>&1
    if not exist "!_keys!\jwt_public.pem" (
        call "%LIB%" :err "Could not create the JWT keys. Is Docker Desktop running?"
        set "WARNINGS=1"
        exit /b 0
    )
    call "%LIB%" :ok "chatty-core\keys: JWT keys created."
)
:: openssl writes the private key as root with mode 600. The core and chat containers run as uid 1000,
:: so hand both files to that user. Also fixes keys made earlier with the chatty-core README commands.
docker run --rm -v "!_keys!:/keys" --entrypoint sh alpine/openssl:3.5.9 -c "chown 1000:1000 /keys/jwt_private.pem /keys/jwt_public.pem" >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :warn "Could not hand the JWT keys to the container user. chatty-core may fail to read them."
    set "WARNINGS=1"
)

:: For running chatty-chat outside Docker. In Docker, chat mounts the file from chatty-core.
if not exist "%CHAT_DIR%" exit /b 0
if not exist "%CHAT_DIR%\keys" mkdir "%CHAT_DIR%\keys"
copy /y "!_keys!\jwt_public.pem" "%CHAT_DIR%\keys\jwt_public.pem" >nul
if errorlevel 1 (
    call "%LIB%" :warn "Could not copy the public key to chatty-chat\keys."
    set "WARNINGS=1"
) else (
    call "%LIB%" :ok "chatty-chat\keys: public key copied from chatty-core."
)
exit /b 0

:random_hex
:: random_hex <bytes> -> HEX, from the OS's cryptographic random generator
set "HEX="
for /f %%h in ('powershell -NoProfile -Command "$b = New-Object byte[] %~1; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') })"') do set "HEX=%%h"
exit /b 0

:venv
:: venv <repo>: create .venv and install requirements.txt, after asking
set "_dir=%WORKSPACE%\%~1"
if not exist "!_dir!\requirements.txt" exit /b 0
if not defined PY (
    call "%LIB%" :info "%~1: no Python 3.14, skipping the virtualenv."
    exit /b 0
)
if exist "!_dir!\.venv\Scripts\python.exe" (
    call "%LIB%" :confirm "%~1 already has a .venv. Update its packages from requirements.txt?"
) else (
    call "%LIB%" :confirm "Create %~1\.venv and install requirements.txt?"
)
if "!CONFIRMED!"=="0" exit /b 0
if not exist "!_dir!\.venv\Scripts\python.exe" (
    !PY! -m venv "!_dir!\.venv"
    if errorlevel 1 (
        call "%LIB%" :warn "%~1: could not create .venv."
        set "WARNINGS=1"
        exit /b 0
    )
)
call "%LIB%" :info "%~1: installing packages, this can take a minute ..."
"!_dir!\.venv\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check -r "!_dir!\requirements.txt"
if errorlevel 1 (
    call "%LIB%" :warn "%~1: pip install failed."
    call "%LIB%" :hint "If Windows Application Control blocks compiled packages like asyncpg, run in Docker instead."
    set "WARNINGS=1"
) else (
    call "%LIB%" :ok "%~1: .venv ready."
)
exit /b 0

:web_packages
if not exist "%WORKSPACE%\chatty-web\package.json" (
    call "%LIB%" :info "chatty-web: no package.json yet, nothing to install."
    exit /b 0
)
where npm >nul 2>&1
if errorlevel 1 (
    call "%LIB%" :warn "chatty-web: npm not found. Install Node.js LTS from https://nodejs.org/"
    set "WARNINGS=1"
    exit /b 0
)
call "%LIB%" :confirm "Install chatty-web's npm packages?"
if "!CONFIRMED!"=="0" exit /b 0
pushd "%WORKSPACE%\chatty-web"
if exist package-lock.json (call npm ci) else (call npm install)
if errorlevel 1 (
    call "%LIB%" :warn "chatty-web: npm install failed."
    set "WARNINGS=1"
) else (
    call "%LIB%" :ok "chatty-web: packages installed."
)
popd
exit /b 0
