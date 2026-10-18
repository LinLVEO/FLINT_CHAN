@echo off
rem FLINT Studio v2 launcher — start server then open browser
cd /d "%~dp0"
start "FLINT Studio server" /min cmd /c "node server.js"
timeout /t 1 /nobreak >nul
start "" http://127.0.0.1:8899
