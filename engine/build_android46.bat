@echo off
rem Buckdroid Roulette (experiment): builds a Godot 4.6.3 Android debug export template from engine\godot46.
rem disable_path_overrides=no lets the engine load the converted game data with --main-pack from the app's folder;
rem the official 4.6 templates are built without that and refuse to start.
rem Needs the Android SDK packages "platforms;android-36", "build-tools;36.1.0" and "ndk;29.0.14206865".
rem If SCons isn't on the PATH, set SCONS_DIR to the folder holding scons.exe first.
set "ROOT=%~dp0.."
for /d %%J in ("%ROOT%\.cache\jdk17\jdk-17*") do set "JAVA_HOME=%%~fJ"
set "ANDROID_HOME=%ROOT%\.cache\android\sdk"
set "ANDROID_SDK_ROOT=%ROOT%\.cache\android\sdk"
set "PATH=%JAVA_HOME%\bin;%SCONS_DIR%;%PATH%"
cd /d "%~dp0godot46"
python -m SCons platform=android target=template_debug arch=arm64 disable_path_overrides=no swappy=yes -j12 || exit /b 1
cd platform\android\java
call .\gradlew.bat generateGodotTemplates || exit /b 1
