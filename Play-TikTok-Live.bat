@echo off
setlocal DisableDelayedExpansion
title Gen1Recomp TikTok LIVE
cd /d "%~dp0" || goto :root_error

set "POKEPORT_REMOTE_PORT=38101"
set "DURATION_MS=120"

echo.
echo === Gen1Recomp TikTok LIVE ===
echo This starts the game and its local-only remote input receiver.
echo.
set /p "TIKTOK_ID=TikTok handle (with or without @): "
if not defined TIKTOK_ID goto :missing_handle

set /p "DURATION_INPUT=Button duration in ms [120]: "
if defined DURATION_INPUT set "DURATION_MS=%DURATION_INPUT%"

for /f %%G in ('powershell.exe -NoProfile -Command "[guid]::NewGuid().ToString('N')"') do set "POKEPORT_REMOTE_TOKEN=%%G"

powershell.exe -NoProfile -Command "$listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 38101 -State Listen -ErrorAction SilentlyContinue; if ($listener) { exit 0 } exit 1" >nul 2>&1
if not errorlevel 1 goto :port_in_use

echo.
echo Starting the game server...
start "Gen1Recomp game server" /D "%CD%" powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -Command "$env:POKEPORT_REMOTE_INPUT='1'; $env:POKEPORT_REMOTE_TOKEN='%POKEPORT_REMOTE_TOKEN%'; $env:POKEPORT_REMOTE_PORT='%POKEPORT_REMOTE_PORT%'; & '.\scripts\run.ps1'"

set /a ATTEMPTS=0
:wait_for_receiver
powershell.exe -NoProfile -Command "$listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 38101 -State Listen -ErrorAction SilentlyContinue; if ($listener) { exit 0 } exit 1" >nul 2>&1
if not errorlevel 1 goto :receiver_ready
set /a ATTEMPTS+=1
if %ATTEMPTS% GEQ 30 goto :receiver_timeout
timeout /t 1 /nobreak >nul
goto :wait_for_receiver

:receiver_ready
echo The game receiver is ready on 127.0.0.1:38101.
echo.
echo Start your TikTok LIVE now. This window will connect after you confirm.
pause
echo Connecting to TikTok LIVE for %TIKTOK_ID%...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-tiktok-bridge.ps1" -UniqueId "%TIKTOK_ID%" -Token "%POKEPORT_REMOTE_TOKEN%" -Port %POKEPORT_REMOTE_PORT% -DurationMs %DURATION_MS%
set "BRIDGE_EXIT=%ERRORLEVEL%"
echo.
echo The TikTok bridge stopped. The game remains open in its own window.
pause
exit /b %BRIDGE_EXIT%

:port_in_use
echo ERROR: port 38101 is already being used. Close the running game server first.
pause
exit /b 1

:receiver_timeout
echo ERROR: the game receiver did not start within 30 seconds.
echo Check the game-server window for an error message.
pause
exit /b 1

:missing_handle
echo ERROR: a TikTok handle is required.
pause
exit /b 1

:root_error
echo ERROR: could not open the project folder.
pause
exit /b 1
