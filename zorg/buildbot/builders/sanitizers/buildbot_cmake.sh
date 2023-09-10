#!/usr/bin/env bash

set -x
set -e
set -u

HERE="$(dirname $0)"
. ${HERE}/buildbot_functions.sh

ARCH=`uname -m`
ninja --version || export PATH="/usr/local/bin:$PATH"

CMAKE_ARGS=""
for arg in "$@"
do
    case $arg in
        --CMAKE_ARGS=*)
        CMAKE_ARGS="${arg#*=}"
    esac
done

# Always clobber bootstrap build trees.
clobber

CMAKE_COMMON_OPTIONS+=" -DLLVM_ENABLE_ASSERTIONS=ON ${CMAKE_ARGS}"

if [ -e /usr/include/plugin-api.h ]; then
  CMAKE_COMMON_OPTIONS+=" -DLLVM_BINUTILS_INCDIR=/usr/include"
fi

# FIXME: Something broken with LLD switch 19cb7a33e82.
CHECK_SYMBOLIZER=1
case "$ARCH" in
  ppc64*)
    CHECK_SYMBOLIZER=0
    CMAKE_COMMON_OPTIONS+=" -DLLVM_TARGETS_TO_BUILD=PowerPC"
    if [[ "$ARCH" == "ppc64le" ]]; then
      CMAKE_COMMON_OPTIONS+=" -DLLVM_LIT_ARGS=-vj256"
    else
      CMAKE_COMMON_OPTIONS+=" -DLLVM_LIT_ARGS=-vj80"
    fi
  ;;
esac

CMAKE_COMMON_OPTIONS+=" -DLLVM_ENABLE_PROJECTS=clang;lld"
CMAKE_COMMON_OPTIONS+=" -DLLVM_ENABLE_RUNTIMES=libcxx;libcxxabi;compiler-rt"
CMAKE_COMMON_OPTIONS+=" -DLLVM_BUILD_LLVM_DYLIB=ON"

buildbot_update

# Use both gcc and just-built Clang/LLD as a host compiler/linker for sanitizer
# tests. Assume that self-hosted build tree should compile with -Werror.
echo @@@BUILD_STEP build fresh toolchain@@@
mkdir -p clang_build
cmake -B clang_build ${CMAKE_COMMON_OPTIONS} $LLVM  || {
  rm -rf clang_build
  build_failure
}
ninja -C clang_build || build_failure

# Check on Linux: build and test sanitizers using gcc as a host
# compiler.
echo @@@BUILD_STEP check-compiler-rt in gcc build@@@
ninja -C clang_build check-compiler-rt || build_failure

### From now on we use just-built Clang as a host compiler ###
CLANG_PATH=${ROOT}/clang_build/bin
# Build self-hosted tree with fresh Clang and -Werror.
CMAKE_COMMON_OPTIONS+=" -DLLVM_ENABLE_WERROR=ON -DCMAKE_C_COMPILER=${CLANG_PATH}/clang -DCMAKE_CXX_COMPILER=${CLANG_PATH}/clang++"

function build_and_test {
  local build_dir=llvm_build64
  echo "@@@BUILD_STEP build compiler-rt ${1}@@@"
  rm -rf ${build_dir}
  mkdir -p ${build_dir}

  cmake -B ${build_dir} ${CMAKE_COMMON_OPTIONS} ${1} $LLVM || build_failure
  ninja -C ${build_dir} || build_failure

  echo "@@@BUILD_STEP test compiler-rt ${1}@@@"
  ninja -C ${build_dir} check-compiler-rt || build_failure
}

if [ "$CHECK_SYMBOLIZER" == "1" ]; then
  build_and_test "-DCOMPILER_RT_ENABLE_INTERNAL_SYMBOLIZER=ON"
fi

build_and_test ""

FRESH_CLANG_PATH=${ROOT}/llvm_build64/bin

echo @@@BUILD_STEP build standalone compiler-rt@@@
mkdir -p compiler_rt_build
cmake -B compiler_rt_build -GNinja \
  -DCMAKE_C_COMPILER=${FRESH_CLANG_PATH}/clang \
  -DCMAKE_CXX_COMPILER=${FRESH_CLANG_PATH}/clang++ \
  -DCOMPILER_RT_INCLUDE_TESTS=ON \
  -DCOMPILER_RT_ENABLE_WERROR=ON \
  -DLLVM_CMAKE_DIR=${ROOT}/llvm_build64 \
  $LLVM/../compiler-rt || build_failure
ninja -C compiler_rt_build || build_failure

echo @@@BUILD_STEP test standalone compiler-rt@@@
ninja -C compiler_rt_build check-all || build_failure

cleanup
