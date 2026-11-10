@echo off
setlocal

rem Windows version of update_geo.sh. Keep this file ASCII-only: cmd misparses
rem UTF-8 comments and may execute fragments of them as commands.
rem
rem Download the latest geoip.dat / geosite.dat (Loyalsoldier enhanced edition)
rem into the directory of this script.
rem Usage:
rem   .\v2ray\update_geo.bat                          direct download
rem   .\v2ray\update_geo.bat http://127.0.0.1:1082    download through a proxy
rem Then copy the files to the paths listed in system_file_location.md

set "BASE=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
set "DIR=%~dp0"
set "PROXY=%~1"
set "PROXY_ARGS="
if not "%PROXY%"=="" set PROXY_ARGS=--proxy "%PROXY%"

if "%PROXY%"=="" (echo No proxy...) else (echo Using proxy: %PROXY%)

call :download geoip.dat || exit /b 1
call :download geosite.dat || exit /b 1

echo Done!
exit /b 0

rem ---------- download one file; replace the old one only on success ----------
:download
set "NAME=%~1"
set "TMPFILE=%DIR%%NAME%.tmp"
echo Downloading %NAME% ...
curl --fail --location --silent --show-error %PROXY_ARGS% --output "%TMPFILE%" "%BASE%/%NAME%"
if errorlevel 1 goto :failed
if not exist "%TMPFILE%" goto :failed
for %%A in ("%TMPFILE%") do if %%~zA==0 goto :failed
move /y "%TMPFILE%" "%DIR%%NAME%" > nul
echo   saved to %DIR%%NAME%
exit /b 0

:failed
if exist "%TMPFILE%" del "%TMPFILE%"
echo [ERROR] failed to download %NAME%, existing file kept 1>&2
exit /b 1
