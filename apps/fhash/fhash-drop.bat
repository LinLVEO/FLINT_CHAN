@echo off
rem fhash-drop.bat - drag a file or a folder onto this file to fingerprint it.
rem   file   -> fhash <file>   (size / mtime / crc32 / md5 / sha256)
rem   folder -> fhash -d <dir> (size + sha256 of every file in the top level)
setlocal
if "%~1"=="" (
  echo Drag a file or a folder onto this .bat
  echo.
  pause
  exit /b 2
)
if exist "%~1\" (
  "%~dp0fhash.exe" -d "%~1"
) else (
  "%~dp0fhash.exe" "%~1"
)
echo.
pause
