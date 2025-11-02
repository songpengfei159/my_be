# check STARROCKS_HOME
if [[ -z ${STARROCKS_HOME} ]]; then
    echo "Error: STARROCKS_HOME is not set"
    exit 1
fi

# set STARROCKS_THIRDPARTY
if [[ -z ${STARROCKS_THIRDPARTY} ]]; then
    export STARROCKS_THIRDPARTY=${STARROCKS_HOME}/thirdparty
fi

# set GCC HOME
if [[ -z ${STARROCKS_GCC_HOME} ]]; then
    export STARROCKS_GCC_HOME=$(dirname `which gcc`)/..
fi


gcc_ver=`${STARROCKS_GCC_HOME}/bin/gcc -dumpfullversion -dumpversion`
required_ver="5.3.1"
if [[ ! "$(printf '%s\n' "$required_ver" "$gcc_ver" | sort -V | head -n1)" = "$required_ver" ]]; then
    echo "Error: GCC version (${gcc_ver}) must be greater than or equal to ${required_ver}"
    exit 1
fi


# export CLANG COMPATIBLE FLAGS
export CLANG_COMPATIBLE_FLAGS=`echo | ${STARROCKS_GCC_HOME}/bin/gcc -Wp,-v -xc++ - -fsyntax-only 2>&1 \
                | grep -E '^\s+/' | awk '{print "-I" $1}' | tr '\n' ' '`


CMAKE_CMD=cmake
if [[ ! -z ${CUSTOM_CMAKE} ]]; then
    CMAKE_CMD=${CUSTOM_CMAKE}
fi
export CMAKE_CMD

CMAKE_GENERATOR="Unix Makefiles"
BUILD_SYSTEM="make"
if ninja --version 2>/dev/null; then
    BUILD_SYSTEM="ninja"
    CMAKE_GENERATOR="Ninja"
fi
export CMAKE_GENERATOR
export BUILD_SYSTEM