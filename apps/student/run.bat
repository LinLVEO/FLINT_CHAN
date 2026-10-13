@echo off
rem student management demo launcher: switch console to UTF-8 so Chinese labels show correctly
chcp 65001 >nul
cd /d "%~dp0"
student.exe
