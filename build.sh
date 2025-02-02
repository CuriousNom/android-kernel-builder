#!/bin/bash
# shellcheck disable=SC1090,SC2086,SC2164,SC2103,SC2155

prepare_env() {
  mkdir -p build
  mkdir -p download

  # updatable part
  CLANG_URL=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz
  AK3_VERSION=db90e19aae369c9c10b956a08003cee3958d50a0

  # set local shell variables
  source config/$DEVICE_CODENAME/$BUILD_CONFIG.conf
  CUR_DIR=$(dirname "$(readlink -f "$0")")
  MAKE_FLAGS=(
    O=out
    ARCH=arm64
    SUBARCH=arm64
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-android-
    CROSS_COMPILE_COMPAT=arm-linux-androideabi-
    CROSS_COMPILE_ARM32=arm-linux-androideabi-
    CC="ccache clang"
    LD=ld.lld
    AS=llvm-as
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    READELF=llvm-readelf
    OBJSIZE=llvm-size
    STRIP=llvm-strip
    LLVM=1
    LLVM_IAS=1
    LLVM_AR=llvm-ar
    LLVM_NM=llvm-nm
  )

  # setup clang
  local clang_pack="$(basename $CLANG_URL)"
  [ -f download/$clang_pack ] || wget -q $CLANG_URL -P download
  mkdir build/clang && tar -C build/clang/ -zxf download/$clang_pack

  # set environment variables
  export PATH=$CUR_DIR/build/clang/bin:$PATH
  export ARCH=arm64
  export SUBARCH=arm64
  export KBUILD_BUILD_USER=${GITHUB_REPOSITORY_OWNER:-pexcn}
  export KBUILD_BUILD_HOST=buildbot
  export KBUILD_COMPILER_STRING="$(clang --version | head -1 | sed 's/ (https.*//')"
  export KBUILD_LINKER_STRING="$(ld.lld --version | head -1 | sed 's/ (compatible.*//')"
}

get_sources() {
  [ -d build/kernel/.git ] || git clone $KERNEL_SOURCE --recurse-submodules build/kernel
  cd build/kernel
  git diff --quiet HEAD || git reset --hard HEAD

  # checkout version
  git checkout $KERNEL_COMMIT

  # remove `-dirty` of version
  sed -i 's/ -dirty//g' scripts/setlocalversion

  cd -
}

add_kernelsu() {
  [ "$DONT_PATCH_KERNELSU" != true ] || return 0

  cd build/kernel

  # integrate kernelsu-next
  curl -sSL "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.4

  # prepare .config
  make "${MAKE_FLAGS[@]}" $KERNEL_CONFIG

  # update .config
  scripts/config --file out/.config \
    --enable CONFIG_MODULES \
    --enable CONFIG_KPROBES \
    --enable CONFIG_HAVE_KPROBES \
    --enable CONFIG_KPROBE_EVENTS

  # re-generate kernel config
  make "${MAKE_FLAGS[@]}" savedefconfig
  cp -f out/defconfig arch/arm64/configs/${KERNEL_CONFIG%% *}

  cd -
}

optimize_config() {
  [ "$DISABLE_OPTIMIZE" != true ] || return 0

  cd build/kernel

  # prepare .config
  make "${MAKE_FLAGS[@]}" $KERNEL_CONFIG

  # enable optimizations
  scripts/config --file out/.config \
    --enable CONFIG_STRIP_ASM_SYMS
  # enable full lto
  scripts/config --file out/.config \
    --disable CONFIG_LTO_NONE \
    --disable CONFIG_THINLTO \
    --enable CONFIG_LTO \
    --enable CONFIG_LTO_CLANG \
    --disable CONFIG_LTO_CLANG_THIN \
    --enable CONFIG_LTO_CLANG_FULL
  # optimize kernel compression
  scripts/config --file out/.config \
    --disable CONFIG_KERNEL_GZIP \
    --enable CONFIG_KERNEL_LZ4 \
    --enable CONFIG_HAVE_KERNEL_LZ4 \
    --enable CONFIG_RD_LZ4 \
    --enable CONFIG_CRYPTO_LZ4
  # optimize network scheduler
  scripts/config --file out/.config \
    --enable CONFIG_NET_SCH_FQ_CODEL \
    --enable CONFIG_NET_SCH_DEFAULT \
    --enable CONFIG_DEFAULT_FQ_CODEL \
    --set-str CONFIG_DEFAULT_NET_SCH "fq_codel"
  # optimize tcp congestion control
  scripts/config --file out/.config \
    --disable CONFIG_TCP_CONG_BIC \
    --disable CONFIG_TCP_CONG_HTCP \
    --enable CONFIG_TCP_CONG_ADVANCED \
    --enable CONFIG_TCP_CONG_BBR \
    --enable CONFIG_TCP_CONG_WESTWOOD \
    --enable CONFIG_DEFAULT_WESTWOOD \
    --set-str CONFIG_DEFAULT_TCP_CONG "westwood"
  # disable unused features
  scripts/config --file out/.config \
    --disable CONFIG_CAN \
    --disable CONFIG_MMC \
    --disable CONFIG_FTRACE
  # disable debug options
  scripts/config --file out/.config \
    --disable CONFIG_ALLOW_DEV_COREDUMP \
    --disable CONFIG_QCOM_MINIDUMP \
    --disable CONFIG_SLUB_DEBUG \
    --disable CONFIG_SPMI_MSM_PMIC_ARB_DEBUG \
    --disable CONFIG_VIDEO_ADV_DEBUG \
    --disable CONFIG_MSM_DEBUGCC_KONA \
    --disable CONFIG_DEBUG_KERNEL \
    --disable CONFIG_DEBUG_ALIGN_RODATA \
    --disable CONFIG_KMALLOC_DEBUG \
    --disable CONFIG_VMALLOC_DEBUG \
    --disable CONFIG_VSERVICES_LOCK_DEBUG \
    --disable CONFIG_DEBUG_INFO \
    --disable CONFIG_SCHED_DEBUG \
    --disable CONFIG_DEBUG_BUGVERBOSE \
    --disable CONFIG_DEBUG_LIST

  # re-generate kernel config
  make "${MAKE_FLAGS[@]}" savedefconfig
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

package_kernel() {
  git clone https://github.com/osm0sis/AnyKernel3.git -b master --single-branch build/anykernel3
  cd build/anykernel3
  git checkout $AK3_VERSION

  # update properties
  sed -i "s/ExampleKernel/\u${BUILD_CONFIG} Kernel for ${GITHUB_WORKFLOW}/; s/by osm0sis @ xda-developers/by ${GITHUB_REPOSITORY_OWNER:-pexcn} @ GitHub/" anykernel.sh
  sed -i '/device.name[1-4]/d' anykernel.sh
  sed -i 's/device.name5=/device.name1='"$DEVICE_CODENAME"'/g' anykernel.sh
  sed -i 's|BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;|BLOCK=auto;|g' anykernel.sh
  sed -i 's/IS_SLOT_DEVICE=0;/IS_SLOT_DEVICE=auto;/g' anykernel.sh
  #sed -i '/^PATCH_VBMETA_FLAG=auto;/a NO_MAGISK_CHECK=1;' anykernel.sh

  # clean folder
  rm -rf .git .github README.md
  find . -name "placeholder" -delete

  # packaging
  cp $CUR_DIR/build/kernel/out/arch/arm64/boot/Image .
  [ ! -f $CUR_DIR/build/kernel/out/arch/arm64/boot/dtb ] || cp $CUR_DIR/build/kernel/out/arch/arm64/boot/dtb .
  [ ! -f $CUR_DIR/build/kernel/out/arch/arm64/boot/dtbo.img ] || cp $CUR_DIR/build/kernel/out/arch/arm64/boot/dtbo.img .
  zip -r $CUR_DIR/build/$DEVICE_CODENAME-$BUILD_CONFIG-kernel.zip ./*

  cd -
}

prepare_env
get_sources
add_kernelsu
optimize_config
build_kernel
package_kernel
