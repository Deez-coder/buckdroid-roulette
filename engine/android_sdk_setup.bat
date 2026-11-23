@echo off
rem Buckdroid Roulette: installs the Android SDK packages Godot 4.1.1 needs into .cache\android\sdk.
rem Running it means accepting Google's Android SDK License Agreement (developer.android.com/studio/terms).
rem Usage:  engine\android_sdk_setup.bat licenses   (answers come from stdin, e.g. piped "yes")
rem         engine\android_sdk_setup.bat install
set "ROOT=%~dp0.."
for /d %%J in ("%ROOT%\.cache\jdk17\jdk-17*") do set "JAVA_HOME=%%~fJ"
set "SDK=%ROOT%\.cache\android\sdk"
set "SM=%SDK%\cmdline-tools\latest\bin\sdkmanager.bat"
if "%1"=="licenses" call "%SM%" --sdk_root="%SDK%" --licenses
if "%1"=="install" call "%SM%" --sdk_root="%SDK%" "platform-tools" "platforms;android-33" "build-tools;33.0.2" "ndk;23.2.8568313" "cmake;3.10.2.4988404"
