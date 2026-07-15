\
@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo THLS Website Crawler V9.0 - Phase 1
echo Folder: %CD%
echo ============================================================
echo.

set "SCRIPT=%CD%\src\thls_crawler.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Script not found:
    echo %SCRIPT%
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -BaseDir "%CD%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Crawler failed. Exit code: %EXIT_CODE%
    echo Check output\latest_log.txt
    pause
    exit /b %EXIT_CODE%
)

echo Crawler completed.
if exist "%CD%\output\latest_report.html" (
    start "" "%CD%\output\latest_report.html"
) else (
    start "" "%CD%\output"
)

echo.
pause
endlocal
