#!/usr/bin/env bash

set -euo pipefail

# Color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Config
KERNEL_DIR=$(pwd)
TOOLCHAIN_DIR=${KERNEL_DIR}/../toolchains
CLANG_DIR=${TOOLCHAIN_DIR}/clang
DATE=$(date +%Y%m%d-%H%M)

# Telegram Config
# BOT_TOKEN=""
# CHAT_ID=""

log() {
  echo -e "$1"
}

check_clang() {
  local CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/167e11df8c330bced88cdf5808f61f41d9eab330/clang-r584948.tar.gz"
  
  if [ ! -f "${CLANG_DIR}/bin/clang" ]; then
    log "${YELLOW}Clang not found, downloading...${NC}"
    mkdir -p ${CLANG_DIR}
    cd ${CLANG_DIR}
    wget ${CLANG_URL} -O clang-r584948.tar.gz
    
    if [ $? -ne 0 ]; then
        log "${RED}Failed to download clang!${NC}"
        exit 1
    fi
    
    log "${YELLOW}Extracting clang...${NC}"
    tar -xzf clang-r584948.tar.gz
    rm clang-r584948.tar.gz
    cd ${KERNEL_DIR}
    log "${GREEN}Clang downloaded successfully!${NC}"
  else
    log "${GREEN}Clang already exists, skipping download${NC}"
  fi
}

verify_clang() {
  if [ ! -f "${CLANG_DIR}/bin/clang" ]; then
    log "${RED}Clang binary not found after extraction!${NC}"
    exit 1
  fi

  log "${GREEN}Clang Version:${NC}"
  ${CLANG_DIR}/bin/clang --version | head -1
}

send_telegram() {
  # Check if telegram config exists
  if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
    log "${YELLOW}Telegram config not set, skipping upload${NC}"
    return 0
  fi

  local file="$1"
  local kernel_ver="$2"
  local msg="*$TITLE*
\`\`\`
$kernel_ver
\`\`\`
*Note: Always backup working boot before flash\\.*"

  log "${YELLOW}Uploading to Telegram...${NC}"
  curl -s -F document=@"$file" "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
    -F chat_id="$CHAT_ID" \
    -F "disable_web_page_preview=true" \
    -F "parse_mode=markdown" \
    -F caption="$msg"
  
  if [ $? -eq 0 ]; then
    log "${GREEN}Upload to Telegram success!${NC}"
  else
    log "${RED}Upload to Telegram failed!${NC}"
  fi
}

build() {
  export PATH="${CLANG_DIR}/bin/:${PATH}"
  log "${YELLOW}Clang in PATH: $(which clang)${NC}"

  # Clean build log
  rm -f build.log

  # Build start
  log "${GREEN}========================================${NC}"
  log "${GREEN}  Starting Build Process${NC}"
  log "${GREEN}========================================${NC}"

  START_TIME=$(date +%s)

  # Make defconfig
  log "${YELLOW}Creating defconfig...${NC}"
  make ARCH=arm64 \
       LLVM=1 \
       LLVM_IAS=1 \
       O=out \
       CROSS_COMPILE=aarch64-linux-gnu- \
       gki_defconfig 2>&1 | tee -a build.log

  if [ ${PIPESTATUS[0]} -ne 0 ]; then
      log "${RED}Defconfig failed! Check build.log${NC}"
      exit 1
  fi

  # Build kernel
  log "${YELLOW}Building kernel image...${NC}"
  make ARCH=arm64 \
       LLVM=1 \
       LLVM_IAS=1 \
       O=out \
       CROSS_COMPILE=aarch64-linux-gnu- \
       -j$(nproc --all) \
       Image 2>&1 | tee -a build.log

  BUILD_STATUS=${PIPESTATUS[0]}
  END_TIME=$(date +%s)
  BUILD_TIME=$((END_TIME - START_TIME))

  # Check result
  if [ ${BUILD_STATUS} -ne 0 ]; then
    log "${RED}========================================${NC}"
    log "${RED}  Build FAILED!${NC}"
    log "${RED}========================================${NC}"
    log "${RED}Check build.log for details${NC}"
    exit 1
  fi

  # Success
  log "${GREEN}========================================${NC}"
  log "${GREEN}  Build SUCCESS!${NC}"
  log "${GREEN}========================================${NC}"
  log "${GREEN}Build time: $((BUILD_TIME / 60))m $((BUILD_TIME % 60))s${NC}"
}

check_file() {
  # Variables
  local KERNEL_IMG="out/arch/arm64/boot/Image"
  local AK_DIR="${KERNEL_DIR}/AK"
  local ZIP="gki-${DATE}.zip"
  local TITLE="GKI-BUILD-${DATE}"
  
  # Check kernel image exists
  if [ ! -f "${KERNEL_IMG}" ]; then
      log "${RED}Kernel image not found!${NC}"
      exit 1
  fi
  
  log "${GREEN}Kernel Image: ${KERNEL_IMG}${NC}"
  ls -lh ${KERNEL_IMG}
  
  # Get kernel version
  local KERNEL_VER=$(strings "$KERNEL_IMG" | grep "Linux version")
  log "${GREEN}Kernel Version: ${KERNEL_VER}${NC}"
  
  # Check/clone AnyKernel3
  if [ -d "$AK_DIR" ]; then
      log "${GREEN}$AK_DIR Found${NC}"
      # Clean old image if exists
      rm -f ${AK_DIR}/Image
  else
      log "${YELLOW}$AK_DIR not found, cloning...${NC}"
      git clone https://github.com/Axelin76/AnyKernel3.git -b gki "$AK_DIR"
  fi
  
  # Copy kernel image
  log "${YELLOW}Copying kernel image to AnyKernel3...${NC}"
  cp ${KERNEL_IMG} ${AK_DIR}/
  
  # Create zip
  log "${YELLOW}Creating flashable zip...${NC}"
  cd ${AK_DIR}
  zip -r9 "../${ZIP}" * -x .git -x .gitignore -x README.md
  cd ${KERNEL_DIR}
  
  if [ -f "${ZIP}" ]; then
      log "${GREEN}Flashable zip created: ${ZIP}${NC}"
      ls -lh ${ZIP}
      
      # Upload to telegram if configured
      send_telegram "$ZIP" "$KERNEL_VER"
  else
      log "${RED}Failed to create zip!${NC}"
      exit 1
  fi
  
  log "${GREEN}========================================${NC}"
  log "${GREEN}  All Done!${NC}"
  log "${GREEN}========================================${NC}"
}

main() {
  check_clang
  verify_clang
  build
  check_file
}

main