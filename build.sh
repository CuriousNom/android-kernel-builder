#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2164,SC2103,SC2155

setup_env() {
  mkdir -p build dl

  # set local shell variables
  source config/$BUILD_CONFIG.conf
  CLANG_URL=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz
  CUR_DIR=$(dirname "$(readlink -f "$0")")
  MAKE_FLAGS=(
    O=out
    ARCH=arm64
    SUBARCH=arm64
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-android-
    CC="ccache clang"
    LD=ld.lld
    LLVM=1
    LLVM_IAS=1
  )

  # set environment variables
  export PATH=$CUR_DIR/build/clang/bin:$PATH
  export ARCH=arm64
  export SUBARCH=arm64
  export KBUILD_BUILD_USER=${GITHUB_REPOSITORY_OWNER:-pexcn}
  export KBUILD_BUILD_HOST=buildbot
  export KBUILD_COMPILER_STRING="$(clang --version | head -1 | sed 's/ (https.*//')"
  export KBUILD_LINKER_STRING="$(ld.lld --version | head -1 | sed 's/ (compatible.*//')"
}

setup_clang() {
  cd build

  local clang_pack="$(basename $CLANG_URL)"
  [ -f $CUR_DIR/dl/$clang_pack ] || wget -q $CLANG_URL -P $CUR_DIR/dl
  mkdir clang && tar -C clang/ -zxf $CUR_DIR/dl/$clang_pack

  cd -
}

get_sources() {
  [ -d build/kernel/.git ] || git clone $KERNEL_SOURCE build/kernel
  cd build/kernel
  git diff --quiet HEAD || git reset --hard HEAD

  # checkout version
  git checkout $KERNEL_COMMIT

  # remove `-dirty` of version
  sed -i 's/ -dirty//g' scripts/setlocalversion

  cd -
}

add_kernelsu() {
  cd build/kernel

  # integrate kernelsu-next
  curl -sSL "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.4

  # update kernel config
  cat <<-EOF >>arch/arm64/configs/${KERNEL_CONFIG%% *}
	CONFIG_MODULES=y
	CONFIG_KPROBES=y
	CONFIG_HAVE_KPROBES=y
	CONFIG_KPROBE_EVENTS=y
	EOF

  # re-generate kernel config
  make "${MAKE_FLAGS[@]}" $KERNEL_CONFIG savedefconfig
  cp -f out/defconfig arch/arm64/configs/${KERNEL_CONFIG%% *}

  cd -
}

build_kernel() {
  cd build/kernel

  # select kernel config
  make "${MAKE_FLAGS[@]}" $KERNEL_CONFIG
  # compile kernel
  make "${MAKE_FLAGS[@]}" -j$(($(nproc) + 1)) || exit 1

  cd -
}

setup_env
setup_clang
get_sources
add_kernelsu
build_kernel
