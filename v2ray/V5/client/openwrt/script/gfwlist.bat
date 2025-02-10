:: 执行 .\v2ray\V5\client\openwrt\script\gfwlist.bat http://127.0.0.1:1082

@echo off

:: --- 如果你想要UTF-8中文正常显示，可以先:
chcp 65001 > nul

:: Hard-code your URL and DEST
set "URL=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
set "DEST=v2ray\V5\client\openwrt\config\dnsmasq mode\dnsmasq\proxy-gfwlist.conf"
set "PROXY=%~1"

:: 下载后暂存的文件
set "TMPFILE=temp_download.txt"

echo Downloading: %URL%
echo Saving to: %DEST%
echo.

:: If user provides proxy parameter
if "%PROXY%"=="" (
    echo No proxy...
    curl --silent --output "%TMPFILE%" "%URL%"
) else (
    echo Using proxy: %PROXY%
    curl --silent --proxy "%PROXY%" --output "%TMPFILE%" "%URL%"
)

:: Check download
if not exist "%TMPFILE%" (
    echo [ERROR] "%TMPFILE%" not found!
    pause
    exit /b 1
)

for %%A in ("%TMPFILE%") do if %%~zA==0 (
    echo [ERROR] "%TMPFILE%" is empty!
    del "%TMPFILE%"
    pause
    exit /b 1
)

echo Processing lines...
:: 第一次调用，只写头部三行
powershell -NoProfile -ExecutionPolicy Bypass -Command "( '# 更新自：https://github.com/Loyalsoldier/v2ray-rules-dat', '# 同步最新发布 gfwlist：https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt', '#' ) | Out-File -FilePath '%DEST%' -Encoding UTF8 -Force"
:: 第二次调用，处理文件内容并追加到目标文件
powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Content '%TMPFILE%') | ForEach-Object { if ($_ -ne '') { 'nftset=/' + $_ + '/4#ip#v2ray#gfwlist' } else { '' } } | Out-File -FilePath '%DEST%' -Encoding UTF8 -Append"

del "%TMPFILE%" >nul 2>&1

echo Done!

exit /b 0
