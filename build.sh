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

# Check args
usage() {
  echo "
Usage: $0 <options>
  Optional options:
     --be               build Backend
     --fe               build Frontend and Spark Dpp application
     --spark-dpp        build Spark DPP application
     --hive-udf         build Hive UDF
     --clean            clean and build target
     --enable-shared-data
                        build Backend with shared-data feature support
     --use-staros       DEPRECATED, an alias of --enable-shared-data option
     --with-gcov        build Backend with gcov, has an impact on performance
     --without-gcov     build Backend without gcov(default)
     --with-bench       build Backend with bench(default without bench)
     --with-clang-tidy  build Backend with clang-tidy(default without clang-tidy)
     --without-java-ext build Backend without java-extensions(default with java-extensions)
     --without-starcache
                        build Backend without starcache library
     -j                 build Backend parallel
     --output-compile-time
                        save a list of the compile time for every C++ file in ${ROOT}/compile_times.txt.
                        Turning this option on automatically disables ccache.
     --with-compress-debug-symbol {ON|OFF}
                        build with compressing debug symbol. (default: $WITH_COMPRESS)
     -h,--help          Show this help message

  Eg.
    $0                                           build all
    $0 --be                                      build Backend without clean
    $0 --fe --clean                              clean and build Frontend and Spark Dpp application
    $0 --fe --be --clean                         clean and build Frontend, Spark Dpp application and Backend
    $0 --spark-dpp                               build Spark DPP application alone
    $0 --hive-udf                                build Hive UDF
    BUILD_TYPE=build_type ./build.sh --be        build Backend is different mode (build_type could be Release, Debug, or Asan. Default value is Release. To build Backend in Debug mode, you can execute: BUILD_TYPE=Debug ./build.sh --be)
  "
  exit 1
}
OPTS=$(getopt \
  -n $0 \
  -o 'hj:' \
  -l 'be' \
  -l 'fe' \
  -l 'spark-dpp' \
  -l 'hive-udf' \
  -l 'clean' \
  -l 'with-gcov' \
  -l 'with-bench' \
  -l 'with-clang-tidy' \
  -l 'without-gcov' \
  -l 'without-java-ext' \
  -l 'without-starcache' \
  -l 'use-staros' \
  -l 'with-brpc-keepalive' \
  -l 'enable-shared-data' \
  -l 'output-compile-time' \
  -l 'with-compress-debug-symbol:' \
  -l 'help' \
  -- "$@")

if [ $? != 0 ] ; then
    usage
fi

eval set -- "$OPTS"

BUILD_BE=
BUILD_FE=
BUILD_SPARK_DPP=
BUILD_HIVE_UDF=
CLEAN=
RUN_UT=
WITH_GCOV=OFF
WITH_BENCH=OFF
WITH_CLANG_TIDY=OFF
WITH_COMPRESS=ON
WITH_STARCACHE=ON
USE_STAROS=OFF
BUILD_JAVA_EXT=ON
OUTPUT_COMPILE_TIME=OFF
MSG=""
MSG_FE="Frontend"
MSG_DPP="Spark Dpp application"
MSG_BE="Backend"
if [[ -z ${USE_AVX2} ]]; then
    USE_AVX2=ON
fi
if [[ -z ${USE_AVX512} ]]; then
    ## Disable it by default
    USE_AVX512=OFF
fi
if [[ -z ${USE_SSE4_2} ]]; then
    USE_SSE4_2=ON
fi
if [[ -z ${JEMALLOC_DEBUG} ]]; then
    JEMALLOC_DEBUG=OFF
fi
if [[ -z ${CCACHE} ]] && [[ -x "$(command -v ccache)" ]]; then
    CCACHE=ccache
fi

if [ -e /proc/cpuinfo ] ; then
    # detect cpuinfo
    if [[ -z $(grep -o 'avx[^ ]\+' /proc/cpuinfo) ]]; then
        USE_AVX2=OFF
    fi
    if [[ -z $(grep -o 'avx512' /proc/cpuinfo) ]]; then
        USE_AVX512=OFF
    fi
    if [[ -z $(grep -o 'sse4[^ ]*' /proc/cpuinfo) ]]; then
        USE_SSE4_2=OFF
    fi
fi

if [[ -z ${ENABLE_QUERY_DEBUG_TRACE} ]]; then
	ENABLE_QUERY_DEBUG_TRACE=OFF
fi

if [[ -z ${ENABLE_FAULT_INJECTION} ]]; then
    ENABLE_FAULT_INJECTION=OFF
fi
HELP=0
if [ $# == 1 ] ; then
    # default. `sh build.sh``
    BUILD_BE=1
    BUILD_FE=1
    BUILD_SPARK_DPP=1
    BUILD_HIVE_UDF=1
    CLEAN=0
    RUN_UT=0
elif [[ $OPTS =~ "-j " ]] && [ $# == 3 ]; then
    # default. `sh build.sh -j 32`
    BUILD_BE=1
    BUILD_FE=1
    BUILD_SPARK_DPP=1
    BUILD_HIVE_UDF=1
    CLEAN=0
    RUN_UT=0
    PARALLEL=$2
else
    BUILD_BE=0
    BUILD_FE=0
    BUILD_SPARK_DPP=0
    BUILD_HIVE_UDF=0
    CLEAN=0
    RUN_UT=0
    while true; do
        case "$1" in
            --be) BUILD_BE=1 ; shift ;;
            --fe) BUILD_FE=1 ; shift ;;
            --spark-dpp) BUILD_SPARK_DPP=1 ; shift ;;
            --hive-udf) BUILD_HIVE_UDF=1 ; shift ;;
            --clean) CLEAN=1 ; shift ;;
            --ut) RUN_UT=1   ; shift ;;
            --with-gcov) WITH_GCOV=ON; shift ;;
            --without-gcov) WITH_GCOV=OFF; shift ;;
            --enable-shared-data|--use-staros) USE_STAROS=ON; shift ;;
            --with-bench) WITH_BENCH=ON; shift ;;
            --with-clang-tidy) WITH_CLANG_TIDY=ON; shift ;;
            --without-java-ext) BUILD_JAVA_EXT=OFF; shift ;;
            --without-starcache) WITH_STARCACHE=OFF; shift ;;
            --output-compile-time) OUTPUT_COMPILE_TIME=ON; shift ;;
            --with-compress-debug-symbol) WITH_COMPRESS=$2 ; shift 2 ;;
            -h) HELP=1; shift ;;
            --help) HELP=1; shift ;;
            -j) PARALLEL=$2; shift 2 ;;
            --) shift ;  break ;;
            *) echo "Internal error" ; exit 1 ;;
        esac
    done
fi

if [[ ${HELP} -eq 1 ]]; then
    usage
    exit
fi
if [ ${CLEAN} -eq 1 ] && [ ${BUILD_BE} -eq 0 ] && [ ${BUILD_FE} -eq 0 ] && [ ${BUILD_SPARK_DPP} -eq 0 ] && [ ${BUILD_HIVE_UDF} -eq 0 ]; then
    echo "--clean can not be specified without --fe or --be or --spark-dpp or --hive-udf"
    exit 1
fi

echo "Get params:
    BUILD_BE            -- $BUILD_BE
    BE_CMAKE_TYPE       -- $BUILD_TYPE
    BUILD_FE            -- $BUILD_FE
    BUILD_SPARK_DPP     -- $BUILD_SPARK_DPP
    BUILD_HIVE_UDF      -- $BUILD_HIVE_UDF
    CCACHE              -- ${CCACHE}
    CLEAN               -- $CLEAN
    RUN_UT              -- $RUN_UT
    WITH_GCOV           -- $WITH_GCOV
    WITH_BENCH          -- $WITH_BENCH
    WITH_CLANG_TIDY     -- $WITH_CLANG_TIDY
    WITH_COMPRESS_DEBUG_SYMBOL  -- $WITH_COMPRESS
    WITH_STARCACHE      -- $WITH_STARCACHE
    ENABLE_SHARED_DATA  -- $USE_STAROS
    USE_AVX2            -- $USE_AVX2
    USE_AVX512          -- $USE_AVX512
    USE_SSE4_2          -- $USE_SSE4_2
    JEMALLOC_DEBUG      -- $JEMALLOC_DEBUG
    PARALLEL            -- $PARALLEL
    ENABLE_QUERY_DEBUG_TRACE -- $ENABLE_QUERY_DEBUG_TRACE
    ENABLE_FAULT_INJECTION -- $ENABLE_FAULT_INJECTION
    BUILD_JAVA_EXT      -- $BUILD_JAVA_EXT
    OUTPUT_COMPILE_TIME   -- $OUTPUT_COMPILE_TIME
"
check_tool()
{
    local toolname=$1
    if [ -e $STARROCKS_THIRDPARTY/installed/bin/$toolname ] ; then
        return 0
    fi
    if which $toolname &>/dev/null ; then
        return 0
    fi
    return 1
}

# check protoc and thrift
for tool in protoc thrift
do
    if ! check_tool $tool ; then
        echo "Can't find command tool '$tool'!"
        exit 1
    fi
done
# Clean and build generated code
echo "Build generated code"
cd ${STARROCKS_HOME}/gensrc
if [ ${CLEAN} -eq 1 ]; then
   make clean
   rm -rf ${STARROCKS_HOME}/fe/fe-core/target
fi
# DO NOT using parallel make(-j) for gensrc
make
cd ${STARROCKS_HOME}
