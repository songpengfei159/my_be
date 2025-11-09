#!/usr/bin/env bash
##############################################################
# This script is used to compile StarRocks
# Usage:
#    sh build.sh --help
# Eg:
#    sh build.sh                                      build all
#    sh build.sh  --be                                build Backend without clean
#    sh build.sh  --fe --clean                        clean and build Frontend and Spark Dpp application
#    sh build.sh  --fe --be --clean                   clean and build Frontend, Spark Dpp application and Backend
#    sh build.sh  --spark-dpp                         build Spark DPP application alone
#    sh build.sh  --hive-udf                          build Hive UDF alone
#    BUILD_TYPE=build_type ./build.sh --be            build Backend is different mode (build_type could be Release, Debug, or Asan. Default value is Release. To build Backend in Debug mode, you can execute: BUILD_TYPE=Debug ./build.sh --be)
#
# You need to make sure all thirdparty libraries have been
# compiled and installed correctly.
##############################################################
startTime=$(date +%s)
ROOT=`dirname "$0"`
ROOT=`cd "$ROOT"; pwd`
MACHINE_TYPE=$(uname -m)

export STARROCKS_HOME=${ROOT}

echo $STARROCKS_HOME

if [ -z $BUILD_TYPE ]; then
    export BUILD_TYPE=Release
fi

cd $STARROCKS_HOME

# 错误就退出
set -eo pipefail
. ${STARROCKS_HOME}/env.sh


if [[ ! -f ${STARROCKS_THIRDPARTY}/installed/llvm/lib/libLLVMInstCombine.a ]]; then
    echo "Thirdparty libraries need to be build ..."
    ${STARROCKS_THIRDPARTY}/build-thirdparty.sh
fi

#PARALLEL=$(sysctl -n hw.ncpu)

PARALLEL=$[$(nproc)/4+1]

