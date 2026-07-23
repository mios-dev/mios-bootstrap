@echo off
:: Forwarding launcher for unified installation\MiOS-Cat.bat
call "%~dp0..\installation\MiOS-Cat.bat" %*
exit /b %ERRORLEVEL%
