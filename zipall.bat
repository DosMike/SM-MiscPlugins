@echo off
set spdir=G:\steam\tf2\tf\addons\sourcemod\scripting
set spcomp=%spdir%\spcomp.exe
set spinc=%spdir%\include
set zipper=F:\Software\7-Zip\7z.exe
echo You are about to compile all plugins in this directory!
pause
if exist Compiled.zip del Compiled.zip
for %%X in (*.sp) do (
  call :compile %%X
)
echo DONE
pause
goto :EOF

:compile
set filename=%~n1
echo ============================================================
echo Compiling %filename%
echo ------------------------------------------------------------
%spcomp% -O2 -i "%spinc%" -v0 %1
%zipper% a -tzip "Compiled.zip" "%filename%.smx" >nul
if exist "%filename%.smx" del "%filename%.smx"
goto :EOF