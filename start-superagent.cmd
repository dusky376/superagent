@echo off
rem ===========================================================================
rem  dsh-superagent - one-click launcher (Windows)
rem
rem  Double-click this file, or run it from a terminal:
rem      start-superagent.cmd
rem      start-superagent.cmd -Restart
rem      start-superagent.cmd -Stop
rem      start-superagent.cmd -Status
rem
rem  Official research prototype (deepseek-ai/dsh-superagent-prototype).
rem  Not an official DeepSeek product; review it before relying on it.
rem ===========================================================================
setlocal
chcp 65001 >nul 2>nul
cd /d "%~dp0"

set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-superagent.ps1" %*
set "RC=%ERRORLEVEL%"

rem Keep the window open when launched by double-click (no -Stop/-Status args
rem and an interactive console), so errors stay readable.
if "%~1"=="" if not defined SUPERAGENT_NO_PAUSE (
  echo.
  pause
)
exit /b %RC%
