@echo off
rem Buckdroid Roulette: builds the patched Godot 4.1.1 Windows runtime (template_debug) for desktop testing.
rem Requires Visual Studio C++ tools and SCons (python -m pip install scons). Output: engine\godot\bin\
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%~dp0godot"
python -m SCons platform=windows target=template_debug -j12 %*
