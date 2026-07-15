@echo off
setlocal

cd /d "%~dp0"

echo THLS Website Crawler V9.0
echo Folder: %CD%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CD%\src\thls_crawler.ps1" -BaseDir "%CD%"

echo.
if errorlevel 1 (
    echo Crawler failed.
    echo Please check the output folder for the latest log.
) else (
    echo Crawler completed.
    echo Opening output folder...
    start "" "%CD%\output"
)

echo.
pause
endlocal
