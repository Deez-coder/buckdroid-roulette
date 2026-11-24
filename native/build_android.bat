@echo off
rem Builds libbdconvert.so (arm64) for the launcher into launcher\jniLibs\arm64-v8a\ (not in git; built from source here).
rem Needs the Android NDK 29.0.14206865 in .cache\android\sdk and engine\godot46 (etcpak and bcdec sources).
set "ROOT=%~dp0.."
set "GD=%ROOT%\engine\godot46\thirdparty"
set "NDK=%ROOT%\.cache\android\sdk\ndk\29.0.14206865"
set "CXX=%NDK%\toolchains\llvm\prebuilt\windows-x86_64\bin\clang++.exe"
if not exist "%ROOT%\launcher\jniLibs\arm64-v8a" mkdir "%ROOT%\launcher\jniLibs\arm64-v8a"
"%CXX%" --target=aarch64-linux-android24 -O2 -fPIC -shared -std=c++17 -static-libstdc++ -fvisibility=hidden -Wl,--build-id=sha1 -Wl,-z,max-page-size=16384 -I"%GD%\etcpak" -I"%GD%\misc" "%ROOT%\native\bdconvert.cpp" "%GD%\etcpak\ProcessRGB.cpp" "%GD%\etcpak\ProcessDxtc.cpp" "%GD%\etcpak\Tables.cpp" "%GD%\etcpak\Dither.cpp" "%GD%\etcpak\DecodeRGB.cpp" -o "%ROOT%\launcher\jniLibs\arm64-v8a\libbdconvert.so" -llog || exit /b 1
