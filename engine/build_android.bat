@echo off
rem Buckdroid Roulette: builds the patched Godot 4.1.1 Android export templates (arm64).
rem Needs: engine\android_sdk_setup.bat done, SCons (python -m pip install --user scons). Output: engine\godot\bin\android_*.apk
rem Usage: engine\build_android.bat [debug|release]   (default debug)
rem Gradle runs "scons" itself and looks for scons.exe on the PATH. If SCons isn't on the PATH, set SCONS_DIR to the
rem folder that contains scons.exe (with pip --user: Python's per-user Scripts folder) before running this.
set "ROOT=%~dp0.."
for /d %%J in ("%ROOT%\.cache\jdk17\jdk-17*") do set "JAVA_HOME=%%~fJ"
set "ANDROID_HOME=%ROOT%\.cache\android\sdk"
set "ANDROID_SDK_ROOT=%ROOT%\.cache\android\sdk"
set "PATH=%JAVA_HOME%\bin;%SCONS_DIR%;%PATH%"
set "TARGET=template_debug"
if "%1"=="release" set "TARGET=template_release"
cd /d "%~dp0godot"
python -m SCons platform=android target=%TARGET% arch=arm64 -j12 || exit /b 1
cd platform\android\java
call gradlew.bat generateGodotTemplates || exit /b 1
