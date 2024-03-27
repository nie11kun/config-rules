@echo off
if "%1" == "h" goto begin
mshta vbscript:createobject("wscript.shell").run("""%~nx0"" h",0)(window.close)&&exit
:begin
REM
taskkill /f /im v2ray.exe
type nul > "C:\Users\Marco Nie\Application\v2ray\log"\access.log
type nul > "C:\Users\Marco Nie\Application\v2ray\log"\error.log
cd "C:\Users\Marco Nie\Application\v2ray"
v2ray run -format jsonv5
exit