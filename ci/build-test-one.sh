#!/bin/bash

if [ -z "$CONDA_DEFAULT_ENV" ] &&
   [ -z "$GITHUB_WORKSPACE" ] &&
   [ -z "$VIRTUAL_ENV" ] && [ -z "$2" ]
then
	echo "Required: use of a virtual environment."
    echo "::set-output name=status::1"
	exit 1
fi

if [ -z "$1" ] ; then
	echo "Usage: $0 sample [--pipenv | --venv]"
	echo "Where:"
	echo "  sample is the name in samples directory (e.g. cryptography)"
	echo "  --pipenv is an option to enable pipenv usage"
	echo "  --venv is an option to enable python venv module usage"
    echo "::set-output name=status::1"
	exit 1
fi

# Verifiy if python is installed
if ! [ -z `which python` ] ; then
    PYTHON=python
elif ! [ -z `which python3` ] ; then
    PYTHON=python3
else
    echo "ERROR: python not found"
    echo "::set-output name=status::1"
    exit
fi

echo "::group::Prepare the environment"
# Presume unexpected error
echo "::set-output name=status::255"
TEST_SAMPLE=$1
if ! [ -z "$2" ] ; then
    MANAGER="$2"
else
    MANAGER=""
fi
# Get script directory (without using /usr/bin/realpath)
CI_DIR=$(cd `dirname "${BASH_SOURCE[0]}"` && pwd)
# This script is on ci subdirectory
TOP_DIR=$(cd "$CI_DIR/.." && pwd)
PY_PLATFORM=$($PYTHON -c "import sysconfig; print(sysconfig.get_platform())")
PY_VERSION=$($PYTHON -c "import sysconfig; print(sysconfig.get_python_version())")
if [[ $PY_PLATFORM == mingw* ]] || [[ $PY_PLATFORM == win* ]] ; then
    echo "Install screenCapture in Windows/MSYS2"
    mkdir -p $HOME/bin
    if ! [ -e $HOME/bin/screenCapture.bat ] ; then
        pushd $HOME/bin
        curl https://raw.githubusercontent.com/npocmaka/batch.scripts/master/hybrids/.net/c/screenCapture.bat -O
        cmd //c screenCapture.bat
        popd
    fi
fi
# Validate bdist_mac action
if ! [[ $PY_PLATFORM == macos* ]] || [ -z "$TEST_BDIST_MAC" ] ; then
    TEST_BDIST_MAC=0
fi
echo "Environment:"
echo "    Platform $PY_PLATFORM"
echo "    Python version $PY_VERSION"
if ! [ -z "$CONDA_EXE" ] ; then
    echo "    $($CONDA_EXE --version)"
fi
echo "::endgroup::"

echo "::group::Check if $TEST_SAMPLE sample exists"
# Check if the samples is in current directory or in a cx_Freeze tree
if [ -d "$TEST_SAMPLE" ] ; then
    TEST_DIR=$(cd "$TEST_SAMPLE" && pwd)
else
    TEST_DIR="${TOP_DIR}/cx_Freeze/samples/$TEST_SAMPLE"
fi
if ! [ -d "$TEST_DIR" ] ; then
    echo "ERROR: Sample's directory NOT found"
    echo "::endgroup::"
    echo "::set-output name=status::1"
    exit
fi
echo "INFO: The sample is available for test"
pushd "$TEST_DIR" >/dev/null
rm Pipfile 2>/dev/null || true
rm Pipfile.lock 2>/dev/null || true
if [ "$MANAGER" == "--pipenv" ] ; then
    $PYTHON -m pip install --upgrade pipenv
    if [ "$OSTYPE" == "msys" ] ; then
        $PYTHON -m pipenv --python $(cygpath -w `which python`)
    else
        $PYTHON -m pipenv --python $(which python)
    fi
elif [ "$MANAGER" == "--venv" ] ; then
    VENV_NAME=cx_Freeze_${TEST_SAMPLE}_py${PY_VERSION}_${PY_PLATFORM}
    if [ -z "$HOME" ] ; then HOME=$PWD ; fi
    VENV_LOCAL=${HOME}/.local/venv/$VENV_NAME
    $PYTHON -m venv $VENV_LOCAL
    if [ $PY_PLATFORM == win-amd64 ] || [ $PY_PLATFORM == win32 ] ; then
        PYTHON=$VENV_LOCAL/Scripts/python.exe
    else
        source $VENV_LOCAL/bin/activate
        PYTHON=python
    fi
fi
echo "::endgroup::"

echo "::group::Install dependencies for $TEST_SAMPLE sample"
WHEELHOUSE="${TOP_DIR}/wheelhouse"
if [ -d "$WHEELHOUSE" ] ; then
    export PIP_FIND_LINKS="$WHEELHOUSE"
fi
export PIP_DISABLE_PIP_VERSION_CHECK=1
$PYTHON "${CI_DIR}/build_test.py" "$TEST_DIR" --install-requires
if [ $? != 0 ]; then
    # somentimes in conda, occurs error 247 if occurs downgrade of python
    $PYTHON "${CI_DIR}/build_test.py" "$TEST_DIR" --install-requires
fi
# start of remove this code
TEST_CXFREEZE="import cx_Freeze; print(cx_Freeze.__version__)"
if ! [ -z "$CONDA_DEFAULT_ENV" ] ; then
    if ! $PYTHON -c "${TEST_CXFREEZE}" 2>/dev/null; then
        echo "::endgroup::"
        pushd $TOP_DIR >/dev/null
        if [ -e linux-64 ] || [ -e osx-64 ] || [ -e win-64 ] ; then
            echo "::group::Install cx-freeze from conda-build"
            $CONDA_EXE install --use-local cx_freeze
        else
            echo "::group::Install cx-freeze from directory of the project"
            # Build the project using the conda python (do not use wheelhouse)
            if [[ $PY_PLATFORM == macos* ]] && ! [ -z "$SDKROOT" ] ; then
                pushd "$SDKROOT/.."
                # export SDKROOT=$(pwd)/$(ls -1d MacOSX11.*.sdk | head -n1)
                popd
            fi
            pip install -e . --no-deps --ignore-installed --no-cache-dir -v
        fi
        popd >/dev/null
    fi
fi
# end of remove this code
echo "::endgroup::"

echo "::group::Show packages"
if [ -e Pipfile ] ; then
    $PYTHON -m pipenv graph
elif ! [ -z "$CONDA_DEFAULT_ENV" ] ; then
    $CONDA_EXE list -n $CONDA_DEFAULT_ENV
else
    $PYTHON -VV
    $PYTHON -m pip list -v
fi
echo "::endgroup::"

echo "::group::Freeze $TEST_SAMPLE sample"
if [ -e Pipfile ] ; then
    $PYTHON -m pipenv run python setup.py build_exe --excludes=tkinter --include-msvcr=true --silent
else
    if [ "$TEST_BDIST_MAC" != "0" ]; then
        $PYTHON setup.py build_exe --excludes=tkinter --silent bdist_mac
    else
        $PYTHON setup.py build_exe --excludes=tkinter --include-msvcr=true --silent
    fi
fi
TEST_EXITCODE=$?
echo "::endgroup::"
if ! [ "$TEST_EXITCODE" == "0" ] ; then
    echo "::set-output name=status::$TEST_EXITCODE"
    exit
fi

echo "::group::Prepare to run the first $TEST_SAMPLE sample"
popd >/dev/null
BUILD_DIR="${TEST_DIR}/build/exe.${PY_PLATFORM}-${PY_VERSION}"
pushd "${BUILD_DIR}" >/dev/null
count=0
TEST_NAME=$($PYTHON "${CI_DIR}/build_test.py" "$TEST_SAMPLE" --get-app=$count)
until [ -z "$TEST_NAME" ] ; do
    # check the app type and remove that info from the app name
    if [[ $TEST_NAME == gui:* ]] ; then
        TEST_APPTYPE=gui
        TEST_NAME=${TEST_NAME:4}
    elif [[ $TEST_NAME == svc:* ]] ; then
        TEST_APPTYPE=svc
        TEST_NAME=${TEST_NAME:4}
    elif [[ $TEST_NAME == cmd:* ]] ; then
        TEST_APPTYPE=cmd
        TEST_NAME=${TEST_NAME:4}
    else
        TEST_APPTYPE=cui
    fi
    TEST_NAME_ARGV=(${TEST_NAME})
    TEST_NAME_BASE=$(basename ${TEST_NAME_ARGV[0]})
    echo "Base: $TEST_NAME_BASE"
    # get the full name for some cases
    if [ "$TEST_APPTYPE" == "cmd" ] ; then
        TEST_NAME_FULL="$TEST_NAME"
    else
        TEST_NAME_FULL="./$TEST_NAME"
        if [ "$TEST_BDIST_MAC" != "0" ] ; then
            # adjust the app name if run on bdist_mac
            names=(../*.app)
            TEST_DIR_BDIST=$(cd "${names[0]}/Contents/MacOS" && pwd)
            TEST_NAME_FULL="$TEST_DIR_BDIST/$TEST_NAME"
            #if [ "$TEST_BDIST_MAC" == "2" ] ; then
            #    mv $TEST_DIR_BDIST/*.dylib $TEST_DIR_BDIST/lib/ || true
            #fi
        fi
    fi
    echo "Full: $TEST_NAME_FULL"
    # log name
    TEST_OUTPUT="$TEST_SAMPLE-$count-$TEST_NAME_BASE-$PY_PLATFORM-$PY_VERSION"
    TEST_LOG="${TEST_OUTPUT}.log"
    echo "Output: $TEST_LOG"
    echo "::endgroup::"
    echo "::group::Run $TEST_NAME"
    # prepare the environment and run the app
    if [ "$TEST_APPTYPE" == "gui" ] ; then
        # GUI app is started in backgound to not block the execution
        if ! [ -z "$GITHUB_WORKSPACE" ] ; then
            # activate the Xvfb as virtual display in the GHA (wait to start)
            if [[ $PY_PLATFORM == linux* ]] ; then
                /sbin/start-stop-daemon --start --quiet \
                  --pidfile /tmp/custom_xvfb_99.pid --make-pidfile \
                  --background --exec \
                  /usr/bin/Xvfb -- :99 -screen 0 1024x768x16 -ac +extension GLX
                  # +render -noreset
                sleep 10
                export DISPLAY=":99.0"
            fi
        fi
        ("$TEST_NAME_FULL" &> "$TEST_LOG" &) && TEST_PID=$!
        # make a screenshot after a timeout
        if [[ $PY_PLATFORM == macos* ]] ; then
            if [ -e /usr/sbin/screencapture ] ; then
                /usr/sbin/screencapture -T 30 "${TEST_OUTPUT}.png"
                echo "Taking a capture of the whole screen to ${TEST_OUTPUT}.png"
            else
                echo "WARNING: screencapture not found"
            fi
        elif [[ $PY_PLATFORM == linux* ]] ; then
            if which gnome-screenshot &>/dev/null ; then
                gnome-screenshot --delay=10 --file="${TEST_OUTPUT}.png"
                echo "Taking a capture of the whole screen to"
                echo "file://${PWD}/${TEST_OUTPUT}.png"
            else
                echo "WARNING: gnome-screenshot not found"
                if which import &>/dev/null ; then
                    echo "INFO: using ImageMagick to capture the screen"
                    sleep 10
                    import -window root "${TEST_OUTPUT}.png"
                    echo "Taking a capture of the whole screen to"
                    echo "file://${PWD}/${TEST_OUTPUT}.png"
                else
                    echo "WARNING: fallback ImageMagick not found"
                fi
            fi
        elif [[ $PY_PLATFORM == mingw* ]] || [[ $PY_PLATFORM == win* ]] ; then
            if [ -e $HOME/bin/screenCapture.exe ] ; then
                sleep 15
                $HOME/bin/screenCapture.exe "${TEST_OUTPUT}.png"
            else
                echo "WARNING: screenCapture not found"
            fi
        fi
    elif [ "$TEST_APPTYPE" == "svc" ] ; then
        # service app is started in backgound too
        ("$TEST_NAME_FULL" &> "$TEST_LOG" &) && TEST_PID=$!
    else
        # for TEST_APPTYPE==cmd - run on current console
        # for TEST_APPTYPE==cui - run console app and capture its results
        if [ ${#TEST_NAME_ARGV[@]} == 1 ] ; then
            ("$TEST_NAME_FULL" &>"$TEST_LOG")
        else
            ($TEST_NAME_FULL &>"$TEST_LOG")
        fi
        TEST_EXITCODE=$?
        TEST_PID=
    fi
    # check for exit code
    if ! [ -z "$TEST_PID" ] ; then
        if kill -0 $TEST_PID ; then
            kill -9 $TEST_PID
            echo "Process $TEST_PID killed after a timeout"
        fi
        if wait $TEST_PID ; then
            TEST_EXITCODE=$(wait $TEST_PID)
            echo "Process $TEST_PID succeeded"
        else
            TEST_EXITCODE=$?
        fi
    fi
    if [ -f "$TEST_LOG" ] ; then
        TEST_LOG_HAS_ERROR=N
        if [ $(wc -c "$TEST_LOG" | awk '{print $1}') != 0 ] ; then
            # generic errors and
            # error for pyqt5
            # error for pyside2
            # error for pythonnet
            if grep -q -i "error:" $TEST_LOG ||
               grep -q -i "Reinstalling the application may f" $TEST_LOG ||
               grep -q -i "Unable to import shiboken" $TEST_LOG ||
               grep -q -i "Unhandled Exception:" $TEST_LOG
            then
                # ignore error for wxPython 4.1.1
                # https://github.com/wxWidgets/Phoenix/commit/040c59fd991cd08174b5acee7de9418c23c9de33
                if [[ $PY_PLATFORM == mingw* ]] &&
                   [ "$TEST_SAMPLE" == "matplotlib" ] &&
                   grep -q 'Error: Unable to set default locale:' $TEST_LOG
                then
                    TEST_LOG_HAS_ERROR=N
                else
                    TEST_LOG_HAS_ERROR=Y
                fi
            fi
        fi
        if [ $TEST_LOG_HAS_ERROR == Y ]; then
            if [ -z "$TEST_EXITCODE" ] || [ "$TEST_EXITCODE" == "0" ] ; then
                TEST_EXITCODE=255
            fi
            echo "Process $TEST_PID error $TEST_EXITCODE"
        elif [ "$TEST_APPTYPE" == "gui" ] ; then
            if ! [ -z "$TEST_EXITCODE" ] && [ "$TEST_EXITCODE" != "0" ] ; then
                echo "Process $TEST_PID error $TEST_EXITCODE IGNORED"
            fi
            TEST_EXITCODE=0
        fi
    fi
    echo "::endgroup::"
    echo "::group::Print output"
    if [[ $PY_PLATFORM == mingw* ]] && [ -z "$GITHUB_WORKSPACE" ] ; then
        (mintty --title "$TEST_NAME" --hold always --exec cat "$TEST_LOG") &
    else
        echo `printf '=%.0s' {1..40}`
        cat "$TEST_LOG"
        echo `printf '=%.0s' {1..40}`
    fi
    if ! [ "$TEST_EXITCODE" == "0" ] ; then
        echo "::endgroup::"
        echo "::set-output name=status::$TEST_EXITCODE"
        exit
    fi
    if [[ $PY_PLATFORM == linux* ]] && [ "$TEST_APPTYPE" == "cui" ] ; then
        echo "::endgroup::"
        echo "::group::Run $TEST_NAME sample in docker"
        docker run --rm -t -v `pwd`:/frozen ubuntu:18.04 /frozen/$TEST_NAME
    fi
    echo "::endgroup::"
    echo "::group::Prepare to run the next $TEST_SAMPLE sample"
    count=$(( $count + 1 ))
    TEST_NAME=$($PYTHON "${CI_DIR}/build_test.py" $TEST_SAMPLE --get-app=$count)
done
popd >/dev/null
echo "::endgroup::"
echo "::set-output name=status::$TEST_EXITCODE"
