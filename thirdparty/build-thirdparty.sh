#!/usr/bin/env bash

set -e

curdir=`dirname "$0"`
curdir=`cd "$curdir"; pwd`

export STARROCKS_HOME=${STARROCKS_HOME:-$curdir/..}
export TP_DIR=$curdir


# set COMPILER
if [[ ! -z ${STARROCKS_GCC_HOME} ]]; then
    export CC=${STARROCKS_GCC_HOME}/bin/gcc
    export CPP=${STARROCKS_GCC_HOME}/bin/cpp
    export CXX=${STARROCKS_GCC_HOME}/bin/g++
    export PATH=${STARROCKS_GCC_HOME}/bin:$PATH
else
    echo "STARROCKS_GCC_HOME environment variable is not set"
    exit 1
fi