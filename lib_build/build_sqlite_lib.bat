@echo off
setlocal enabledelayedexpansion
rem ============================================================
rem build_sqlite_lib.bat: build the static sqlite3.lib this package
rem links against, with MSVC (cl.exe and lib.exe).
rem
rem Windows counterpart to build_sqlite_lib.sh, with the same
rem compile options. It compiles the amalgamation directly rather
rem than using Makefile.msc, which only builds the DLL and shell and
rem enables FTS, RTREE and other extensions by default.
rem
rem Usage, from the package root, in an "x64 Native Tools Command
rem Prompt for VS":
rem   lib_build\build_sqlite_lib.bat C:\path\to\sqlite-autoconf-XXXXXXX
rem   set "SQLITE_SRC_DIR=C:\path\to\sqlite-autoconf-XXXXXXX" & lib_build\build_sqlite_lib.bat
rem
rem Environment:
rem   OUTPUT_DIR   Where to put sqlite3.lib (default: the package
rem                root, where bindings.odin expects it).
rem   SKIP_VERIFY  Set to 1 to skip the compile_options check.
rem
rem The CRT is linked statically (/MT); change CFLAGS below if your
rem Odin build needs otherwise. The check compiles check_opts.c
rem (shared with build_sqlite_lib.sh) against the new library.
rem ============================================================

if not "%~1"=="" set "SQLITE_SRC_DIR=%~1"
if "%SQLITE_SRC_DIR%"=="" (
    echo error: no SQLite source directory given. 1>&2
    echo usage: %~nx0 C:\path\to\sqlite-autoconf-XXXXXXX 1>&2
    echo    or: set "SQLITE_SRC_DIR=C:\path\to\sqlite-autoconf-XXXXXXX" ^& %~nx0 1>&2
    exit /b 1
)

rem Strip a trailing backslash: in "C:\src\" it would escape the
rem closing quote when passed to cl.exe.
if "%SQLITE_SRC_DIR:~-1%"=="\" set "SQLITE_SRC_DIR=%SQLITE_SRC_DIR:~0,-1%"

rem Make the path absolute; it is used again after pushd.
for %%I in ("%SQLITE_SRC_DIR%") do set "SQLITE_SRC_DIR=%%~fI"

if not exist "%SQLITE_SRC_DIR%\" (
    echo error: '%SQLITE_SRC_DIR%' is not a directory. 1>&2
    exit /b 1
)

if not exist "%SQLITE_SRC_DIR%\sqlite3.c" (
    echo error: '%SQLITE_SRC_DIR%' doesn't look like an extracted 1>&2
    echo        SQLite source tree; expected to find sqlite3.c 1>&2
    echo        and sqlite3.h directly inside it. 1>&2
    exit /b 1
)
if not exist "%SQLITE_SRC_DIR%\sqlite3.h" (
    echo error: '%SQLITE_SRC_DIR%' doesn't look like an extracted 1>&2
    echo        SQLite source tree; expected to find sqlite3.c 1>&2
    echo        and sqlite3.h directly inside it. 1>&2
    exit /b 1
)

rem --- resolve output location and this script's own directory --------------

set "SCRIPT_DIR=%~dp0"
rem Default to the package root. Two separate ifs rather than
rem if/else: a for loop at the end of an if block confuses cmd.exe's
rem parsing of a following else.
if "%OUTPUT_DIR%"=="" for %%I in ("%SCRIPT_DIR%..") do set "OUTPUT_DIR=%%~fI"
if "%OUTPUT_DIR:~-1%"=="\" set "OUTPUT_DIR=%OUTPUT_DIR:~0,-1%"
if not exist "%OUTPUT_DIR%\" mkdir "%OUTPUT_DIR%"

if not exist "%SCRIPT_DIR%check_opts.c" (
    echo error: check_opts.c not found next to this script 1>&2
    echo        ^(expected at %SCRIPT_DIR%check_opts.c^). 1>&2
    exit /b 1
)

rem --- toolchain check --------------------------------------------------

where cl >nul 2>nul
if errorlevel 1 (
    echo error: cl.exe not found on PATH. 1>&2
    echo        Run this from the "x64 Native Tools Command Prompt for VS", 1>&2
    echo        or otherwise set up the MSVC build environment first. 1>&2
    exit /b 1
)
where lib >nul 2>nul
if errorlevel 1 (
    echo error: lib.exe not found on PATH. 1>&2
    exit /b 1
)

echo == Toolchain ==
where cl
where lib
cl 2>&1 | findstr /c:"Microsoft"
echo.
echo If this is not the compiler you meant (another cl.exe
echo earlier on PATH), fix PATH or run this from the
echo correct "x64 Native Tools Command Prompt for VS" window.
echo.

rem --- build ---------------------------------------------------------------

rem Same options as build_sqlite_lib.sh. /Gy and /Gw are the MSVC
rem equivalents of -ffunction-sections and -fdata-sections.
set "CFLAGS=/nologo /O2 /MT /Gy /Gw"
set "CFLAGS=%CFLAGS% /D SQLITE_OMIT_DEPRECATED"
set "CFLAGS=%CFLAGS% /D SQLITE_OMIT_LOAD_EXTENSION"
set "CFLAGS=%CFLAGS% /D SQLITE_OMIT_JSON"
set "CFLAGS=%CFLAGS% /D SQLITE_OMIT_GEOPOLY"
set "CFLAGS=%CFLAGS% /D SQLITE_OMIT_PROGRESS_CALLBACK"
set "CFLAGS=%CFLAGS% /D SQLITE_OMIT_AUTOINIT"
set "CFLAGS=%CFLAGS% /D SQLITE_DQS=0"
set "CFLAGS=%CFLAGS% /D SQLITE_DEFAULT_FOREIGN_KEYS=1"

echo == Building in %SQLITE_SRC_DIR% ==
pushd "%SQLITE_SRC_DIR%"

rem Remove artifacts from any earlier build with different flags.
del /q sqlite3.obj sqlite3.lib >nul 2>nul

cl %CFLAGS% /c /Fo:sqlite3.obj sqlite3.c
if errorlevel 1 (
    echo error: compile failed. 1>&2
    popd
    exit /b 1
)

lib /nologo /MACHINE:X64 /OUT:sqlite3.lib sqlite3.obj
if errorlevel 1 (
    echo error: archive failed. 1>&2
    popd
    exit /b 1
)

echo.
echo == Built: %SQLITE_SRC_DIR%\sqlite3.lib ==
dir /b sqlite3.lib

rem --- verify the actual compiled-in feature set ------------------------------
rem
rem Link a probe against the library and ask it which options are
rem compiled in, as build_sqlite_lib.sh does.

if /i not "%SKIP_VERIFY%"=="1" (
    echo.
    echo == Verifying compile_options against the built library ==

    cl /nologo /MT /O2 /I "%SQLITE_SRC_DIR%" "%SCRIPT_DIR%check_opts.c" sqlite3.lib /Fe:check_opts.exe
    if errorlevel 1 (
        echo error: failed to build the verification probe. 1>&2
        popd
        exit /b 1
    )

    check_opts.exe > check_opts_output.txt
    if errorlevel 1 (
        echo error: verification probe failed to run. 1>&2
        popd
        exit /b 1
    )

    echo Actual compile_options from the built library:
    for /f "usebackq delims=" %%L in ("check_opts_output.txt") do echo   %%L
    echo.

    rem Only the on/off choices this build makes. Items are quoted
    rem because = separates items in a for list.
    set "FAILED=0"

    for %%O in ("OMIT_DEPRECATED" "OMIT_LOAD_EXTENSION" "OMIT_JSON" "OMIT_PROGRESS_CALLBACK" "OMIT_AUTOINIT" "DQS=0" "DEFAULT_FOREIGN_KEYS") do (
        findstr /b /c:"%%~O" check_opts_output.txt >nul
        if errorlevel 1 (
            echo   MISSING expected option: %%~O 1>&2
            set "FAILED=1"
        )
    )

    for %%O in (ENABLE_RTREE ENABLE_FTS3 ENABLE_FTS4 ENABLE_DBSTAT_VTAB HAVE_ZLIB) do (
        findstr /b /c:"%%O" check_opts_output.txt >nul
        if not errorlevel 1 (
            echo   UNEXPECTEDLY PRESENT: %%O 1>&2
            set "FAILED=1"
        )
    )

    del /q check_opts.exe check_opts.obj check_opts_output.txt >nul 2>nul

    if "!FAILED!"=="1" (
        echo.
        echo error: built library's actual compile_options ^(listed above^) 1>&2
        echo        don't match what this build is supposed to produce. 1>&2
        popd
        exit /b 1
    )

    echo   OK: expected options present, excluded subsystems absent.
)

rem --- install ----------------------------------------------------------

copy /y sqlite3.lib "%OUTPUT_DIR%\sqlite3.lib" >nul
if errorlevel 1 (
    echo error: failed to copy sqlite3.lib to %OUTPUT_DIR% 1>&2
    popd
    exit /b 1
)

popd

echo.
echo == Installed ==
echo %OUTPUT_DIR%\sqlite3.lib
dir /b "%OUTPUT_DIR%\sqlite3.lib"
echo.
endlocal
exit /b 0
