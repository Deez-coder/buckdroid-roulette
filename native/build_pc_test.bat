@echo off
rem Builds the PC test tool for native\bdconvert.cpp (bdconvert.exe in .work\), used by tools\check_bdconvert.py to
rem compare the launcher's texture conversion with Godot 4.6's own. Needs Visual Studio (C++ tools) and engine\godot46.
set "ROOT=%~dp0.."
set "GD=%ROOT%\engine\godot46\thirdparty"
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%ROOT%\.work"
cl /nologo /O2 /EHsc /std:c++17 /DBDCONVERT_CLI /DNOMINMAX /I"%GD%\etcpak" /I"%GD%\misc" "%ROOT%\native\bdconvert.cpp" "%GD%\etcpak\ProcessRGB.cpp" "%GD%\etcpak\ProcessDxtc.cpp" "%GD%\etcpak\Tables.cpp" "%GD%\etcpak\Dither.cpp" "%GD%\etcpak\DecodeRGB.cpp" /Fe:bdconvert.exe || exit /b 1
