cmake_minimum_required(VERSION 3.11.1)

set(STARROCKS_GCC_HOME "/usr/bin/..")
set(ENV{CC} "${STARROCKS_GCC_HOME}/bin/gcc")
set(ENV{CXX} "${STARROCKS_GCC_HOME}/bin/g++")
# 设置编译器
if (DEFINED ENV{CC} AND DEFINED ENV{CXX})
    set(CMAKE_C_COMPILER "$ENV{CC}")
    set(CMAKE_CXX_COMPILER "$ENV{CXX}")
elseif (DEFINED ENV{STARROCKS_GCC_HOME})
    # prefer GCC
    set(CMAKE_C_COMPILER "$ENV{STARROCKS_GCC_HOME}/bin/gcc")
    set(CMAKE_CXX_COMPILER "$ENV{STARROCKS_GCC_HOME}/bin/g++")
elseif (DEFINED ENV{STARROCKS_LLVM_HOME})
    set(CMAKE_C_COMPILER "$ENV{STARROCKS_LLVM_HOME}/bin/clang")
    set(CMAKE_CXX_COMPILER "$ENV{STARROCKS_LLVM_HOME}/bin/clang++")
else()
    # 打印环境变量 CC
    message(FATAL_ERROR "STARROCKS_GCC_HOME environment variable is not set")
endif()

# disable pkgconfig searching libraries, all libraries are static imported
set(CMAKE_DISABLE_FIND_PACKAGE_PkgConfig ON)
# Workaround error of `Unknown CMake command "pkg_check_modules".'`
# refer to: https://gitlab.kitware.com/cmake/cmake/-/issues/17043
macro( pkg_check_modules )
endmacro()

project(starrocks CXX C)

# set CMAKE_BUILD_TYPE
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RELEASE)
endif()

string(TOUPPER ${CMAKE_BUILD_TYPE} CMAKE_BUILD_TYPE)
message(STATUS "Build type is ${CMAKE_BUILD_TYPE}")

# set CMAKE_BUILD_TARGET_ARCH
# use `lscpu | grep 'Architecture' | awk '{print $2}'` only support system which language is en_US.UTF-8
execute_process(COMMAND bash "-c" "uname -m"
        OUTPUT_VARIABLE
        CMAKE_BUILD_TARGET_ARCH
        OUTPUT_STRIP_TRAILING_WHITESPACE)
message(STATUS "Build target arch is ${CMAKE_BUILD_TARGET_ARCH}")

# Set dirs
set(BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(RELATIVE_BASE_DIR "be")
set(FILE_PREFIX_MAP_FLAG "-ffile-prefix-map=${BASE_DIR}=${RELATIVE_BASE_DIR}")
set(BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}")
set(THIRDPARTY_DIR "$ENV{STARROCKS_THIRDPARTY}/installed/")
set(STARROCKS_THIRDPARTY "$ENV{STARROCKS_THIRDPARTY}")
set(SRC_DIR "${BASE_DIR}/src")
set(GENSRC_DIR "${SRC_DIR}/gen_cpp/build")
set(TEST_DIR "${CMAKE_SOURCE_DIR}/test/")
set(OUTPUT_DIR "${BASE_DIR}/output")
set(CONTRIB_DIR "${BASE_DIR}/../contrib/")
set(CMAKE_EXPORT_COMPILECOMMANDS ON)

if (APPLE)
    set(MAKE_TEST "ON")
else()
    option(MAKE_TEST "ON for make unit test or OFF for not" OFF)
endif()
message(STATUS "make test: ${MAKE_TEST}")

option(WITH_GCOV "Build binary with gcov to get code coverage" OFF)

option(WITH_COMPRESS "Build binary with compresss debug section" ON)

option(WITH_CACHELIB "Build binary with cachelib library" OFF)

option(WITH_STARCACHE "Build binary with starcache library" ON)
option(WITH_BRCP_KEEPALIVE "Build binary with brpc_socket_keepalive (requires brpc 1.8)" OFF)

option(WITH_BENCH "Build binary with bench" OFF)

option(USE_STAROS "Use StarOS to manager tablet info" OFF)

option(USE_SSE4_2 "Build with SSE4.2 instruction" ON)

option(USE_AVX2 "Build with AVX2 instruction" ON)

option(USE_AVX512 "Build with AVX512f/AVX512BW instruction" OFF)

# Check gcc
if (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    if (CMAKE_CXX_COMPILER_VERSION VERSION_LESS "4.8.2")
        message(FATAL_ERROR "Need GCC version at least 4.8.2")
    endif()

    if (CMAKE_CXX_COMPILER_VERSION VERSION_GREATER "10.3.0")
        message(STATUS "GCC version ${CMAKE_CXX_COMPILER_VERSION} is greater than 10.3.0, disable -Werror. Be careful with compile warnings.")
    else()
        #   -Werror: compile warnings should be errors when using the toolchain compiler.
        set(CXX_GCC_FLAGS "${CXX_GCC_FLAGS} -Werror")
    endif()
elseif (CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
elseif (NOT APPLE)
    message(FATAL_ERROR "Compiler should be GNU")
endif()

# Compile generated source if necessary
message(STATUS "build gensrc if necessary")
execute_process(COMMAND make -C ${BASE_DIR}/gensrc/
        RESULT_VARIABLE MAKE_GENSRC_RESULT)
if(NOT ${MAKE_GENSRC_RESULT} EQUAL 0 AND NOT APPLE)
    message(FATAL_ERROR "Failed to build ${BASE_DIR}/gensrc/")
endif()

#
set(BUILD_VERSION_CC ${CMAKE_BINARY_DIR}/build_version.cc)
configure_file(${SRC_DIR}/common/build_version.cc.in ${BUILD_VERSION_CC} @ONLY)
add_library(build_version OBJECT ${BUILD_VERSION_CC})
target_include_directories(build_version PRIVATE ${SRC_DIR}/common)

# Add common cmake prefix path and link library path
list(APPEND CMAKE_PREFIX_PATH ${THIRDPARTY_DIR}/lib/cmake)
list(APPEND CMAKE_PREFIX_PATH ${THIRDPARTY_DIR}/lib64/cmake)
link_directories(${THIRDPARTY_DIR}/lib ${THIRDPARTY_DIR}/lib64)

# support to pass cxx flags from environment.
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} $ENV{STARROCKS_CXX_COMMON_FLAGS}")

# -no-pie: Disable Position Independent Executables (PIE) as certain libraries cannot be linked against PIE executables.
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -no-pie")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} $ENV{STARROCKS_CXX_LINKER_FLAGS}")

# compiler flags that are common across debug/release builds
#  -Wall: Enable all warnings.
#  -Wno-sign-compare: suppress warnings for comparison between signed and unsigned
#    integers
#   -fno-strict-aliasing: disable optimizations that assume strict aliasing. This
#       is unsafe to do if the code uses casts (which we obviously do).
#  -Wno-unknown-pragmas: suppress warnings for unknown (compiler specific) pragmas
#  -Wno-deprecated: gutil contains deprecated headers
#  -Wno-vla: we use C99-style variable-length arrays
#  -pthread: enable multithreaded malloc
#  -DBOOST_DATE_TIME_POSIX_TIME_STD_CONFIG: enable nanosecond precision for boost
#  -fno-omit-frame-pointers: Keep frame pointer for functions in register
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wall -Wno-sign-compare -Wno-unknown-pragmas -pthread -Wno-register")
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-strict-aliasing -fno-omit-frame-pointer")
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -std=gnu++20 -D__STDC_FORMAT_MACROS")
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-deprecated -Wno-vla -Wno-comment")
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} ${FILE_PREFIX_MAP_FLAG}")
# disable link delete(void*, long)
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -fno-sized-deallocation")

if (CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    if (NOT ${MAKE_TEST} STREQUAL "ON")
        # there are too many warnings reported by clang in be/test and it will take some time to fix.
        # temporarily disable Werror in the unit test so that clang can compile.
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Werror")
    endif()
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-unused-parameter -Wno-documentation -Wno-weak-vtables")
    # Turn on following warning as error explicitly
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Werror=string-plus-int")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Werror=pessimizing-move")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Werror=delete-non-virtual-dtor")
    if (CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "11.0.0")
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-reserved-identifier -Wno-suggest-destructor-override")
    endif()
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-documentation-unknown-command -Wno-old-style-cast")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-c++20-designator -Wno-mismatched-tags")
    if (CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "14.0.0")
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-bitwise-instead-of-logical -Wno-inconsistent-missing-override -Wno-ambiguous-reversed-operator")
    endif()
    if (CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL "16.0.0")
        # ignore warning from apache-orc
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Wno-unsafe-buffer-usage")
    endif ()
else ()
    set(CXX_GCC_FLAGS "${CXX_GCC_FLAGS} -fcoroutines")
endif()

set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DBOOST_DATE_TIME_POSIX_TIME_STD_CONFIG")
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DBOOST_SYSTEM_NO_DEPRECATED -DBOOST_UUID_RANDOM_PROVIDER_FORCE_POSIX")
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -Werror=return-type -Werror=switch")
if (${USE_STAROS} STREQUAL "ON")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DUSE_STAROS")
endif()
if (${WITH_CACHELIB} STREQUAL "ON")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DWITH_CACHELIB")
endif()
if (${WITH_STARCACHE} STREQUAL "ON")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DWITH_STARCACHE")
endif()

# When LLVM is used, should give GCC_HOME to get c++11 header to use new string and list
if (CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    if (DEFINED ENV{STARROCKS_GCC_HOME})
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} --gcc-toolchain=$ENV{STARROCKS_GCC_HOME}")
    else()
        message(WARNING "STARROCKS_GCC_HOME evnironment variable is not set, ")
    endif()
endif()

if ("${CMAKE_BUILD_TARGET_ARCH}" STREQUAL "x86" OR "${CMAKE_BUILD_TARGET_ARCH}" STREQUAL "x86_64")
    if (${USE_SSE4_2})
        # the compiler will define __SSE4_2__
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -msse4.2")
    endif()
    if (${USE_AVX2})
        # the compiler will define __AVX2__
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -mavx2")
    endif()
    if (${USE_AVX512})
        # the compiler will define __AVX512F__ __AVX512BW__
        set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -mavx512f -mavx512bw")
    endif()
elseif ("${CMAKE_BUILD_TARGET_ARCH}" STREQUAL "aarch64")
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -march=armv8-a+crc")
endif()
set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS}  -Wno-attributes -DS2_USE_GFLAGS -DS2_USE_GLOG")

if (CMAKE_CXX_COMPILER_VERSION VERSION_GREATER 7.0)
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -faligned-new")
endif()

# For any gcc builds:
#   -g: Enable symbols for profiler tools
#   -Wno-unused-local-typedefs: Do not warn for local typedefs that are unused.
set(CXX_GCC_FLAGS "${CXX_GCC_FLAGS} -g -Wno-unused-local-typedefs")

if (WITH_GCOV)
    # To generate flags to code coverage
    set(CXX_GCC_FLAGS "${CXX_GCC_FLAGS} -fprofile-arcs -ftest-coverage")
endif()

if (WITH_COMPRESS)
    # to compresss debug section. https://gcc.gnu.org/onlinedocs/gcc/Debugging-Options.html
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -gz=zlib")
endif()

if (ENABLE_QUERY_DEBUG_TRACE)
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DENABLE_QUERY_DEBUG_TRACE")
    message(STATUS "enable query debug trace")
endif()

if (ENABLE_FAULT_INJECTION)
    set(CXX_COMMON_FLAGS "${CXX_COMMON_FLAGS} -DFIU_ENABLE")
    message(STATUS "enable fault injection")
endif()

# For CMAKE_BUILD_TYPE=Debug
#   -ggdb: Enable gdb debugging
# Debug information is stored as dwarf2 to be as compatible as possible
#   -Werror: compile warnings should be errors when using the toolchain compiler.
# Only enable for debug builds because this is what we test in pre-commit tests.
set(CXX_FLAGS_DEBUG "${CXX_GCC_FLAGS} -ggdb -O0 -gdwarf-4 -DDEBUG")

# For CMAKE_BUILD_TYPE=Release
#   -O3: Enable all compiler optimizations
#   -DNDEBUG: Turn off dchecks/asserts/debug only code.
#   -gdwarf-4: Debug information is stored as dwarf2 to be as compatible as possible
set(CXX_FLAGS_RELEASE "${CXX_GCC_FLAGS} -O3 -gdwarf-4 -DNDEBUG")

SET(CXX_FLAGS_ASAN "${CXX_GCC_FLAGS} -ggdb3 -O0 -gdwarf-4 -fsanitize=address -DADDRESS_SANITIZER")
SET(CXX_FLAGS_LSAN "${CXX_GCC_FLAGS} -ggdb3 -O0 -gdwarf-4 -fsanitize=leak -DLEAK_SANITIZER")

# Set the flags to the undefined behavior sanitizer, also known as "ubsan"
# Turn on sanitizer and debug symbols to get stack traces:
SET(CXX_FLAGS_UBSAN "${CXX_FLAGS_RELEASE} -fsanitize=undefined")
# Ignore a number of noisy errors with too many false positives:
# TODO(zc):
# SET(CXX_FLAGS_UBSAN "${CXX_FLAGS_UBSAN} -fno-sanitize=alignment,function,vptr,float-divide-by-zero,float-cast-overflow")
# Don't enforce wrapped signed integer arithmetic so that the sanitizer actually sees

# Set the flags to the thread sanitizer, also known as "tsan"
# Turn on sanitizer and debug symbols to get stack traces:
SET(CXX_FLAGS_TSAN "${CXX_GCC_FLAGS} -O0 -ggdb3 -fsanitize=thread -DTHREAD_SANITIZER")

# Set compile flags based on the build type.
if ("${CMAKE_BUILD_TYPE}" STREQUAL "DEBUG")
    SET(CMAKE_CXX_FLAGS ${CXX_FLAGS_DEBUG})
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "RELEASE")
    SET(CMAKE_CXX_FLAGS ${CXX_FLAGS_RELEASE})
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "ASAN")
    SET(CMAKE_CXX_FLAGS "${CXX_FLAGS_ASAN}")
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "LSAN")
    SET(CMAKE_CXX_FLAGS "${CXX_FLAGS_LSAN}")
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "UBSAN")
    SET(CMAKE_CXX_FLAGS "${CXX_FLAGS_UBSAN}")
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "TSAN")
    SET(CMAKE_CXX_FLAGS "${CXX_FLAGS_TSAN}")
else()
    message(FATAL_ERROR "Unknown build type: ${CMAKE_BUILD_TYPE}")
endif()

# Add flags that are common across build types
SET(CMAKE_CXX_FLAGS "${CXX_COMMON_FLAGS} ${CMAKE_CXX_FLAGS}")
# apply -ffile-prefix-map option to .c source files as well
SET(CMAKE_C_FLAGS "${FILE_PREFIX_MAP_FLAG} ${CMAKE_C_FLAGS}")

message(STATUS "Compiler Flags: ${CMAKE_CXX_FLAGS}")
# Thrift requires these two definitions for some types that we use
add_definitions(-DHAVE_INTTYPES_H -DHAVE_NETINET_IN_H)

set(WL_START_GROUP "-Wl,--start-group")
set(WL_END_GROUP "-Wl,--end-group")
set(WL_LINK_STATIC "-Wl,-Bstatic")
set(WL_LINK_DYNAMIC "-Wl,-Bdynamic")

# Set starrocks libraries
set(STARROCKS_LINK_LIBS
        ${WL_START_GROUP}
        Agent
        Common
        Column
        Connector
        Exec
        Exprs
        FileSystem
        Formats
        Gutil
        IO
        Serde
        Storage
        Rowset
        Runtime
        Service
        ServiceBE
        Types
        Udf
        Util
        Script
        StarRocksGen
        Webserver
        TestUtil
        Tools
        Geo
        BlockCache
        ${WL_END_GROUP}
)
set(STARROCKS_DEPENDENCIES ${STARROCKS_DEPENDENCIES}
        mysql
)


set(STARROCKS_DEPENDENCIES ${STARROCKS_DEPENDENCIES}
        hdfs
        jvm
)

if (${WITH_CACHELIB} STREQUAL "ON")
    set(STARROCKS_DEPENDENCIES
            ${STARROCKS_DEPENDENCIES}
            ${WL_START_GROUP}
            ${Boost_LIBRARIES}
            ${CACHELIB_DEPENDENCIES}
            ${WL_END_GROUP}
    )
endif()

if (${WITH_STARCACHE} STREQUAL "ON")
    set(STARROCKS_DEPENDENCIES
            ${STARROCKS_DEPENDENCIES}
            ${WL_START_GROUP}
            brpc
            starcache
            ${WL_END_GROUP}
    )
endif()

if ("${CMAKE_BUILD_TARGET_ARCH}" STREQUAL "x86" OR "${CMAKE_BUILD_TARGET_ARCH}" STREQUAL "x86_64")
    set(STARROCKS_DEPENDENCIES
            ${STARROCKS_DEPENDENCIES}
            breakpad
            libdeflate
    )
endif()

# Add all external dependencies. They should come after the starrocks libs.
set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} ${STARROCKS_DEPENDENCIES})

set(BUILD_FOR_SANITIZE "OFF")
# Add sanitize static link flags or jemalloc
if ("${CMAKE_BUILD_TYPE}" STREQUAL "DEBUG" OR "${CMAKE_BUILD_TYPE}" STREQUAL "RELEASE")
    message("use jemalloc")
    set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} jemalloc)
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "ASAN")
    if (CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
        set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -static-libsan)
    else()
        set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -static-libasan)
    endif()
    set(BUILD_FOR_SANITIZE "ON")
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "LSAN")
    set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -static-liblsan)
    set(BUILD_FOR_SANITIZE "ON")
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "UBSAN")
    message("use jemalloc")
    set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -static-libubsan jemalloc)
    set(BUILD_FOR_SANITIZE "ON")
elseif ("${CMAKE_BUILD_TYPE}" STREQUAL "TSAN")
    set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -static-libtsan)
    set(BUILD_FOR_SANITIZE "ON")
else()
    message(FATAL_ERROR "Unknown build type: ${CMAKE_BUILD_TYPE}")
endif()

if (NOT ("${MAKE_TEST}" STREQUAL "ON" AND "${BUILD_FOR_SANITIZE}" STREQUAL "ON"))
    # In other words, turn to dynamic link when MAKE_TEST and BUILD_TYPE == *SAN
    # otherwise do static link gcc's lib
    set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -static-libstdc++ -static-libgcc)
endif()

set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS}
        ${WL_LINK_STATIC} -lbfd
        ${WL_LINK_DYNAMIC} -lresolv -liberty -lc -lm -ldl -rdynamic -pthread -Wl,-wrap=__cxa_throw
)

# link gcov if WITH_GCOV is on
if (WITH_GCOV)
    set(STARROCKS_LINK_LIBS ${STARROCKS_LINK_LIBS} -lgcov)
endif()

# Set libraries for test
set (TEST_LINK_LIBS ${STARROCKS_LINK_LIBS}
        ${WL_START_GROUP}
        gmock
        gtest
        ${WL_END_GROUP}
)

# Only build static libs
set(BUILD_SHARED_LIBS OFF)

if (NOT $ENV{STARROCKS_LINKER} STREQUAL "")
    add_link_options("-fuse-ld=$ENV{STARROCKS_LINKER}")
endif ()

if (${MAKE_TEST} STREQUAL "ON")
    SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DGTEST_USE_OWN_TR1_TUPLE=0")
    add_definitions(-DBE_TEST)
    add_definitions(-DFIU_ENABLE)
else()
    # output *.a, *.so, *.dylib to output/tmp
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}/tmp/${CMAKE_BUILD_TYPE})
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}/tmp/${CMAKE_BUILD_TYPE})
    # output *.exe to output/lib
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}/lib)
endif ()

# Utility CMake function to make specifying tests and benchmarks less verbose
FUNCTION(ADD_BE_TEST TEST_NAME)
    set(BUILD_OUTPUT_ROOT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/")
    # This gets the directory where the test is from (e.g. 'exprs' or 'runtime')
    get_filename_component(DIR_NAME ${CMAKE_CURRENT_SOURCE_DIR} NAME)
    get_filename_component(TEST_DIR_NAME ${TEST_NAME} PATH)
    get_filename_component(TEST_FILE_NAME ${TEST_NAME} NAME)

    ADD_EXECUTABLE(${TEST_FILE_NAME} ${TEST_NAME}.cpp)
    TARGET_LINK_LIBRARIES(${TEST_FILE_NAME} ${TEST_LINK_LIBS} gtest_main)
    SET_TARGET_PROPERTIES(${TEST_FILE_NAME} PROPERTIES COMPILE_FLAGS "-fno-access-control")
    if (NOT "${TEST_DIR_NAME}" STREQUAL "")
        SET_TARGET_PROPERTIES(${TEST_FILE_NAME} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${BUILD_OUTPUT_ROOT_DIRECTORY}/${TEST_DIR_NAME}")
    endif()
    ADD_TEST(${TEST_FILE_NAME} "${BUILD_OUTPUT_ROOT_DIRECTORY}/${TEST_NAME}")
ENDFUNCTION()

# Add a benchmark to BE
FUNCTION(ADD_BE_BENCH BENCH_NAME)
    message(STATUS "Add Be Bench")
    set(BUILD_OUTPUT_ROOT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/")
    # This gets the directory where the test is from (e.g. 'exprs' or 'runtime')
    get_filename_component(DIR_NAME ${CMAKE_CURRENT_SOURCE_DIR} NAME)
    get_filename_component(BENCH_DIR_NAME ${BENCH_NAME} PATH)
    set(BENCH_OUTPUT_DIR_NAME "output")
    get_filename_component(BENCH_FILE_NAME ${BENCH_NAME} NAME)

    find_package(benchmark REQUIRED)
    ADD_EXECUTABLE(${BENCH_FILE_NAME} ${BENCH_NAME}.cpp)
    TARGET_LINK_LIBRARIES(${BENCH_FILE_NAME} ${TEST_LINK_LIBS} benchmark benchmark_main)

    SET_TARGET_PROPERTIES(${BENCH_FILE_NAME} PROPERTIES COMPILE_FLAGS "-fno-access-control")
    SET_TARGET_PROPERTIES(${BENCH_FILE_NAME} PROPERTIES COMPILE_FLAGS ${CXX_FLAGS_RELEASE})
    if (NOT "${BENCH_OUTPUT_DIR_NAME}" STREQUAL "")
        SET_TARGET_PROPERTIES(${BENCH_FILE_NAME} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${BUILD_OUTPUT_ROOT_DIRECTORY}/${BENCH_OUTPUT_DIR_NAME}")
    endif()
    ADD_TEST(${BENCH_FILE_NAME} "${BUILD_OUTPUT_ROOT_DIRECTORY}/${BENCH_NAME}")
ENDFUNCTION()

add_subdirectory(${SRC_DIR}/column)
#add_subdirectory(${SRC_DIR}/gen_cpp)
add_subdirectory(${SRC_DIR}/gutil)
add_subdirectory(${SRC_DIR}/storage)

if (WITH_BENCH STREQUAL "ON")
    message(STATUS "Build binary with bench")
    add_subdirectory(${SRC_DIR}/bench)
endif()

# Install be
install(DIRECTORY DESTINATION ${OUTPUT_DIR})
install(DIRECTORY DESTINATION ${OUTPUT_DIR}/bin)
install(DIRECTORY DESTINATION ${OUTPUT_DIR}/conf)
install(DIRECTORY DESTINATION ${OUTPUT_DIR}/lib)

install(FILES
        ${BASE_DIR}/../bin/common.sh
        ${BASE_DIR}/../bin/start_backend.sh
        ${BASE_DIR}/../bin/start_be.sh
        ${BASE_DIR}/../bin/start_cn.sh
        ${BASE_DIR}/../bin/stop_be.sh
        ${BASE_DIR}/../bin/stop_cn.sh
        ${BASE_DIR}/../bin/show_be_version.sh
        ${BASE_DIR}/../bin/meta_tool.sh
        PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
        GROUP_READ GROUP_WRITE GROUP_EXECUTE
        WORLD_READ WORLD_EXECUTE
        DESTINATION ${OUTPUT_DIR}/bin)

install(FILES
        ${BASE_DIR}/../conf/be.conf
        ${BASE_DIR}/../conf/be_test.conf
        ${BASE_DIR}/../conf/cn.conf
        ${BASE_DIR}/../conf/hadoop_env.sh
        ${BASE_DIR}/../conf/log4j2.properties
        ${BASE_DIR}/../conf/udf_security.policy
        ${BASE_DIR}/../conf/core-site.xml
        DESTINATION ${OUTPUT_DIR}/conf)

if ("${CMAKE_BUILD_TYPE}" STREQUAL "ASAN" OR "${CMAKE_BUILD_TYPE}" STREQUAL "LSAN")
    install(FILES
            ${BASE_DIR}/../conf/asan_suppressions.conf
            DESTINATION ${OUTPUT_DIR}/conf)
endif()

install(DIRECTORY
        ${BASE_DIR}/../webroot/be/
        DESTINATION ${OUTPUT_DIR}/www)

# 打印 STARROCKS_GCC_HOME
project(my_be)

set(CMAKE_CXX_STANDARD 11)

add_executable(my_be main.cpp)
