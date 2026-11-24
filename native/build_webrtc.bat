@echo off
rem Builds the WebRTC GDExtension (godotengine/webrtc-native 1.2.2, MIT) from source for multiplayer.
rem   native\build_webrtc.bat windows   -> .cache\webrtc-native\bin\windows\  (PC test build of the game)
rem   native\build_webrtc.bat android   -> launcher\jniLibs\arm64-v8a\libwebrtc_native.android.template_debug.arm64.so
rem Source: git clone --depth 1 --branch 1.2.2-stable --recurse-submodules https://github.com/godotengine/webrtc-native.git .cache\webrtc-native
rem Needs Visual Studio C++ tools, SCons, Visual Studio's CMake and Ninja and NDK 29 (Android).
set "ROOT=%~dp0.."
set "VSCM=C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake"
set "PATH=%VSCM%\CMake\bin;%VSCM%\Ninja;%SCONS_DIR%;%PATH%"
rem libdatachannel needs CMake 3.21+ (Visual Studio's CMake 4.x); some dependencies still declare very old minimums.
set "CMAKE_POLICY_VERSION_MINIMUM=3.5"
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d "%ROOT%\.cache\webrtc-native"
rem Lets godot-cpp use the vcvars environment (SCons may not know the installed Visual Studio).
git -C godot-cpp apply --check "%ROOT%\native\patches\godot-cpp-msvc-env.patch" 2>nul && git -C godot-cpp apply "%ROOT%\native\patches\godot-cpp-msvc-env.patch"
if /i "%1"=="android" goto android
python -m SCons platform=windows target=template_debug arch=x86_64 -j12 || exit /b 1
goto :eof
:android
set "ANDROID_HOME=%ROOT%\.cache\android\sdk"
set "ANDROID_NDK_ROOT=%ROOT%\.cache\android\sdk\ndk\29.0.14206865"
python -m SCons platform=android target=template_debug arch=arm64 android_api_level=24 -j12 || exit /b 1
if not exist "%ROOT%\launcher\jniLibs\arm64-v8a" mkdir "%ROOT%\launcher\jniLibs\arm64-v8a"
for /r bin\android %%F in (libwebrtc_native*.so) do copy /y "%%F" "%ROOT%\launcher\jniLibs\arm64-v8a\" >nul
