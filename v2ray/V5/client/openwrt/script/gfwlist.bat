:: 执行 .\v2ray\V5\client\openwrt\script\gfwlist.bat http://127.0.0.1:1082

@echo off

:: 如果想要在命令提示符下看到正常的中文，请先执行:
chcp 65001 > nul

:: Hard-code your URL and DEST
set "URL=https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
set "DEST=v2ray\V5\client\openwrt\config\dnsmasq mode\dnsmasq\proxy-gfwlist.conf"
set "PROXY=%~1"

:: 下载后暂存的文件
set "TMPFILE=temp_download.txt"

echo Downloading: %URL%
echo Saving to: %DEST%
echo.

:: 如果未提供代理参数，直接下载；否则带代理下载
if "%PROXY%"=="" (
    echo No proxy...
    curl --silent --output "%TMPFILE%" "%URL%"
) else (
    echo Using proxy: %PROXY%
    curl --silent --proxy "%PROXY%" --output "%TMPFILE%" "%URL%"
)

:: 判断文件是否存在
if not exist "%TMPFILE%" (
    echo [ERROR] "%TMPFILE%" not found!
    pause
    exit /b 1
)

:: 判断文件是否为空
for %%A in ("%TMPFILE%") do if %%~zA==0 (
    echo [ERROR] "%TMPFILE%" is empty!
    del "%TMPFILE%"
    pause
    exit /b 1
)

echo Processing lines...

:: 使用 PowerShell，实现：
:: 1. 读取 TMPFILE 内容
:: 2. 生成头部数组
:: 3. 过滤需要跳过的域名（完全匹配）
:: 4. 根据每行生成 "nftset=/<域名>/4#ip#v2ray#gfwlist"
:: 5. 用 .NET UTF8Encoding($False) 写入无 BOM 的 UTF-8 文件
powershell -NoProfile -ExecutionPolicy Bypass ^
    -Command ^
    "$skipDomains = @('apple.com', 'qq.com'); " ^
    "$lines = Get-Content '%TMPFILE%'; " ^
    "$header = '# 更新自：https://github.com/Loyalsoldier/v2ray-rules-dat', '# 同步最新发布 proxy-list：https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt', '# proxy list 比 gfwlist 更全', '#'; " ^
    "$lines2 = $lines | ForEach-Object { " ^
    "  if ($_ -match '^regexp:') { return } " ^
    "  $d = $_ -replace '^full:', ''; " ^
    "  if ($skipDomains -contains $d) { return } " ^
    "  if ($d -ne '') { 'nftset=/' + $d + '/4#ip#v2ray#gfwlist' } else { '' } " ^
    "}; " ^
    "[System.IO.File]::WriteAllLines('%DEST%', ($header + $lines2), (New-Object System.Text.UTF8Encoding($false)))"

:: 删除临时文件
del "%TMPFILE%" >nul 2>&1

echo Done!

exit /b 0
