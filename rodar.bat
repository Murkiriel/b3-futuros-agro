@echo off
rem Atualiza b3_futuros_agro.xlsx com os pregões que ainda faltam.
rem Argumentos extras são repassados ao script (ex.: rodar.bat --refazer).
cd /d "%~dp0"
"C:\Python\python.exe" "%~dp0b3_futuros_agro.py" %*
if errorlevel 1 pause
