@rem  Builds JetBrainsRuntime JDK25 for Windows ARM64.
@rem  Usage:
@rem   build-jbr25-win-aarch64.cmd [-q]
@rem The JDK is built in <OUT_DIR> (or "%TMP%\out" if unset).
@rem Following artifacts are created in <%TMP%\out> ("%TMP%\out\dist" if unset):
@rem   jdk.zip
@rem   jdk-runtime.zip
@rem   jdk-debuginfo.zip
@rem   configure.log
@rem   build.log
@rem Specify -q to suppress most of the output noise

@echo "In build-jbr25-win-aarch64.cmd"
@echo "Environment variables:"
@echo "==================================================="
set
@echo "==================================================="

@setlocal enabledelayedexpansion

IF [%OUT_DIR%] == [] if [%TMPDIR%] NEQ [] (set OUT_DIR=%TMPDIR%\out)
IF [%OUT_DIR%] == [] if [%TMP%] NEQ [] (set OUT_DIR=%TMP%\out)

set SCRIPT_DIR=%~dp0
set CYGWIN_DIR=c:\tools\cygwin
if "%~1"=="-q" set QUIET="-q"

%CYGWIN_DIR%\bin\bash -l %SCRIPT_DIR%build-jbr25-win-aarch64.sh %QUIET%
