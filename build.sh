#!/usr/bin/env bash

set -eu

# ci redefined
BUILD_DIR=${BUILD_DIR:-build}
OUTPUT_DIR=${OUTPUT_DIR:-output}
VENV_DIR=${VENV_DIR:-venv}
ABI=${ABI:-rv64}
BOARD=${BOARD:-canmv}
ARCH=${ARCH:-riscv}
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-unknown-linux-gnu-}
TIMESTAMP=${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}

DISTRO=${DISTRO:-gentoo_musl_rv32} # yocto_rv32 / fedora_rv32 / gentoo_musl_rv32 / fedora_rv64
CHROOT_TARGET=${CHROOT_TARGET:-target}
ROOTFS_IMAGE_SIZE=2G
ROOTFS_IMAGE_FILE="k230_root.ext4"

LINUX_BUILD=${LINUX_BUILD:-build}
OPENSBI_BUILD=${OPENSBI_BUILD:-build}
UBOOT_BUILD=${UBOOT_BUILD:-build-uboot}

mkdir -p ${BUILD_DIR} ${OUTPUT_DIR} ${CHROOT_TARGET}

OUTPUT_DIR=$(readlink -f ${OUTPUT_DIR})
SCRIPT_DIR=$(readlink -f $(dirname $0))

function build_linux() {
  pushd linux
  {
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${LINUX_BUILD} k230_evb_linux_enable_vector_defconfig
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${LINUX_BUILD} -j$(nproc) dtbs
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${LINUX_BUILD} -j$(nproc)

    cp -v ${LINUX_BUILD}/vmlinux ${OUTPUT_DIR}/vmlinux_${ABI}
    cp -v ${LINUX_BUILD}/arch/riscv/boot/Image ${OUTPUT_DIR}/Image_${ABI}
    cp -v Documentation/admin-guide/kdump/gdbmacros.txt ${OUTPUT_DIR}/gdbmacros_${ABI}.txt
    cp -v ${LINUX_BUILD}/arch/riscv/boot/dts/canaan/k230_evb.dtb ${OUTPUT_DIR}/k230_evb_${ABI}.dtb
    cp -v ${LINUX_BUILD}/arch/riscv/boot/dts/canaan/k230_canmv.dtb ${OUTPUT_DIR}/k230_canmv_${ABI}.dtb
  }
  popd
}

function build_opensbi() {
  pushd opensbi
  {
    make \
      ARCH=${ARCH} \
      CROSS_COMPILE=${CROSS_COMPILE} \
      O=${OPENSBI_BUILD} \
      PLATFORM=generic \
      FW_PAYLOAD=y \
      FW_FDT_PATH=${OUTPUT_DIR}/k230_${BOARD}_${ABI}.dtb \
      FW_PAYLOAD_PATH=${OUTPUT_DIR}/Image_${ABI} \
      FW_TEXT_START=0x0 \
      -j $(nproc)
    cp -v ${OPENSBI_BUILD}/platform/generic/firmware/fw_payload.bin ${OUTPUT_DIR}/k230_${BOARD}_${ABI}.bin
  }
  popd
}

function build_uboot() {
  python3 -m venv ${VENV_DIR}
  source ${VENV_DIR}/bin/activate
  pip install gmssl
  pushd uboot
  {
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${UBOOT_BUILD} k230_${BOARD}_defconfig
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} O=${UBOOT_BUILD} -j$(nproc)
    cp -av ${UBOOT_BUILD}/u-boot-spl-k230.bin ${OUTPUT_DIR}/u-boot-spl-k230_${BOARD}.bin
    cp -av ${UBOOT_BUILD}/fn_u-boot.img ${OUTPUT_DIR}/fn_u-boot_${BOARD}.img
  }
  popd
  deactivate
}

function build_rootfs() {
  pushd ${OUTPUT_DIR}
  {
    if [[ $DISTRO == "fedora_rv32" ]]; then
      curl -OL https://github.com/ruyisdk/mkimg-k230-rv64ilp32/releases/download/fedora_rv32_rootfs/root.ext4.zst
      unzstd root.ext4.zst
      mv root.ext4 ${ROOTFS_IMAGE_FILE}
    elif [[ $DISTRO == "yocto_rv32" ]]; then
      curl -OL https://github.com/ruyisdk/mkimg-k230-rv64ilp32/releases/download/fedora_rv32_rootfs/core-image-minimal-qemuriscv32.rootfs-20240302042035.ext4.zst
      unzstd core-image-minimal-qemuriscv32.rootfs-20240302042035.ext4.zst
      mv core-image-minimal-qemuriscv32.rootfs-20240302042035.ext4 ${ROOTFS_IMAGE_FILE}
    elif [[ $DISTRO == "fedora_rv64" ]]; then
      curl -OL https://github.com/ruyisdk/mkimg-k230-rv64ilp32/releases/download/fedora_rv32_rootfs/root-lp64.ext4.zst
      unzstd root-lp64.ext4.zst
      mv root-lp64.ext4 ${ROOTFS_IMAGE_FILE}
    elif [[ $DISTRO == "gentoo_musl_rv32" ]]; then
      curl -OL https://github.com/RevySR/mkimg-k230-gentoo-rv32/releases/download/rootfs/root_gentoo_musl32.ext4.zst
      unzstd root_gentoo_musl32.ext4.zst
      mv root_gentoo_musl32.ext4 ${ROOTFS_IMAGE_FILE}
    else
      echo "DISTRO: ${DISTRO} ?????"
      exit 1
    fi
  }
  popd
  
}

function build_img() {
  genimage --config configs/${BOARD}.cfg \
    --inputpath "${OUTPUT_DIR}" \
    --outputpath "${OUTPUT_DIR}" \
    --rootpath="$(mktemp -d)"
}

function fix_permissions() {
  chown -R $USER ${OUTPUT_DIR}
}

function cleanup_build() {
  check_euid_root
  pushd ${SCRIPT_DIR}
  {
    mountpoint -q ${CHROOT_TARGET} && umount -l ${CHROOT_TARGET}
    rm -rvf ${OUTPUT_DIR} ${BUILD_DIR} ${CHROOT_TARGET}
    rm -rvf uboot/${UBOOT_BUILD} opensbi/${OPENSBI_BUILD} linux/${LINUX_BUILD}
    rm -rvf ${VENV_DIR}
  }
  popd
}

function usage() {
  echo "Usage: $0 build/clean"
}

function fault() {
  usage
  exit 1
}

function check_euid_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
  fi
}

function main() {
  if [[ $# < 1 ]]; then
    fault
  fi

  if [ "$1" = "build" ]; then
    if [ "$2" = "linux" ]; then
      build_linux
    elif [ "$2" = "opensbi" ]; then
      build_opensbi
    elif [ "$2" = "uboot" ]; then
      build_uboot
    elif [ "$2" = "rootfs" ]; then
      check_euid_root
      build_rootfs
      fix_permissions
    elif [ "$2" = "img" ]; then
      build_img
    elif [ "$2" = "linux_opensbi_uboot" ]; then
      build_linux
      build_opensbi
      build_uboot
    elif [ "$2" = "all" ]; then
      check_euid_root
      build_linux
      build_opensbi
      build_uboot
      build_rootfs
      build_img
      fix_permissions
    else
      fault
    fi
  elif [ "$1" = "clean" ]; then
    cleanup_build
  else
    fault
  fi
}

main $@
