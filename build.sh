#!/usr/bin/env bash
# Build the Xiaomi Mi 6 (sagit) UniXNU boot image on an Ubuntu runner.
# Produces: edk2-msm8998/workspace/out/boot-sagit.img
#
# Expected next to this script (checked out by the workflow):
#   unixnu-src/        UniXNU/UniXNU with submodules
#   unixnu-sagit/      ilertnost/unixnu-sagit
#   edk2-msm8998/      edk2-porting/edk2-msm8998 (branch "new")
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(nproc)"
PREFIX=/opt/unixnu-linux
export TMPDIR="${RUNNER_TEMP:-/tmp}"

IPSW_URL="https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77002/0281BFC6-38ED-485A-A8BE-8871861174B1/iPhone_4.7_P3_16.7.16_20H392_Restore.ipsw"
IPSW_SHA256="601cb23e740dacf8b61271fe02ffd5b3c146b518abb5a6e6b286e5f0475fe43b"
GCC_VER="13.2.Rel1"
GCC_TAR="arm-gnu-toolchain-${GCC_VER}-x86_64-aarch64-none-linux-gnu"
GCC_URL="https://developer.arm.com/-/media/Files/downloads/gnu/13.2.rel1/binrel/${GCC_TAR}.tar.xz"
CHIP_ID="0x8015"                  # Apple A11 (mirrored identity)
UNIQUE_CHIP="0x80150001A7FEC139"  # stable per-device platform seed (serial a7fec139)
DRAM="0xf0000000"                 # matches dts/sagit.dts memory window

echo "== host packages =="
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  git patch flex bison bzip2 cpio rsync curl wget ca-certificates tcsh unifdef \
  cmake clang lld mtools gettext \
  build-essential pkg-config ninja-build python3 python3-dev xz-utils \
  libssl-dev zlib1g-dev libbsd-dev uuid-dev llvm-dev libclang-dev device-tree-compiler

echo "== install OS profile into UniXNU =="
mkdir -p "$ROOT/unixnu-src/profiles/os"
rm -rf "$ROOT/unixnu-src/profiles/os/ios-16.7.16-20H392"
cp -a "$ROOT/unixnu-sagit/profiles/os/ios-16.7.16-20H392" "$ROOT/unixnu-src/profiles/os/"

echo "== UniXNU Linux toolchain (cached across runs) =="
if [ ! -x "$PREFIX/llvm/bin/clang" ]; then
  sudo env TMPDIR="$TMPDIR" python3 "$ROOT/unixnu-src/scripts/linux/setup-toolchain.py" "$PREFIX" -j "$JOBS"
fi
sudo env TMPDIR="$TMPDIR" python3 "$ROOT/unixnu-src/scripts/linux/setup-toolchain.py" --check
# The GitHub cache action packs the prefix as the runner user.
sudo chown -R "$(id -u):$(id -g)" "$PREFIX"

echo "== arm gnu toolchain 13.2 =="
if [ ! -d "$ROOT/$GCC_TAR" ]; then
  curl -fL --retry 3 -o "$TMPDIR/gcc.tar.xz" "$GCC_URL"
  tar -C "$ROOT" -xf "$TMPDIR/gcc.tar.xz"
fi
export PATH="$ROOT/$GCC_TAR/bin:$PATH"
aarch64-none-linux-gnu-gcc --version | head -1

echo "== iPhone10,1 20H392 IPSW =="
if [ ! -f "$ROOT/iphone8.ipsw" ]; then
  curl -fL --retry 3 -o "$ROOT/iphone8.ipsw" "$IPSW_URL"
fi
echo "$IPSW_SHA256  $ROOT/iphone8.ipsw" | sha256sum -c -

echo "== unixnu fetch =="
cd "$ROOT/unixnu-src"
python3 ./unixnu fetch -D "$ROOT/unixnu-sagit"

echo "== kernelcache (decompressed, pin-checked) =="
KC="$(python3 ./unixnu ipsw fetch KernelCache -D "$ROOT/unixnu-sagit" --ipsw "$ROOT/iphone8.ipsw" | tail -1)"
export UNIXNU_KERNELCACHE="$KC"
echo "kernelcache: $KC"
# The 14 GB runner disk is tight during the toolchain phase: drop the 6 GB
# IPSW as soon as the kernelcache is extracted.
rm -f "$ROOT/iphone8.ipsw"

echo "== XNU kernel =="
SRC="$ROOT/unixnu-src" TOOLCHAIN="$PREFIX" "$ROOT/unixnu-sagit/tools/build-xnu-sagit.sh"

echo "== Apple device tree =="
cd "$ROOT/unixnu-sagit"
mkdir -p out/adt out
UNIXNU_SRC="$ROOT/unixnu-src" python3 tools/make-sagit-adt.py \
  --output out/adt/kernel.macho.adt \
  --chip-id "$CHIP_ID" \
  --unique-chip-id "$UNIQUE_CHIP" --dram-size "$DRAM"

echo "== payload volume =="
# The canonical payload kernel is the PRELINKED kernel (Apple kext closure from
# the 20H392 kernelcache merged into the native build), repacked by the device's
# stripper to fit the Mi 6 boot-image limit. Fall back to the native .noctf when
# the board runs without prelink.
PK="$ROOT/unixnu-src/out/sagit/ios-16.7.16-20H392/sagit/kernel/kernel.macho"
K="$ROOT/unixnu-src/out/sagit/ios-16.7.16-20H392/sagit/tree/build/xnu/ios-obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837.unstripped.noctf"
if [ -f "$PK" ]; then
  python3 tools/strip-prelinked-kernel.py "$PK" out/kernel.macho
  echo "payload kernel: prelinked -> stripped"
else
  [ -f "$K" ] || { echo "kernel missing: $K" >&2; exit 1; }
  cp "$K" out/kernel.macho
  echo "payload kernel: native .noctf (prelink skipped)"
fi
ls -l out/kernel.macho
python3 tools/mksagit-payload.py \
  --kernel out/kernel.macho --adt out/adt/kernel.macho.adt \
  --output out/sagit-payload-volume.img \
  --size-mib 44 --timeout 3 \
  --args="-v -enable_kprintf_spam debug=0x14e" --lzma
ls -l out/sagit-payload-volume.img*

echo "== EDK2 firmware + boot-sagit.img =="
PAYLOAD="$ROOT/unixnu-sagit/out/sagit-payload-volume.img.lzma" \
ROOT="$ROOT/edk2-msm8998" \
TOOLCHAIN="$ROOT/$GCC_TAR" \
UNIXNU_SRC="$ROOT/unixnu-src" \
  "$ROOT/unixnu-sagit/tools/build-sagit-edk2.sh"

echo "== artifact =="
ls -la "$ROOT/edk2-msm8998/workspace/out/boot-sagit.img"
sha256sum "$ROOT/edk2-msm8998/workspace/out/boot-sagit.img"
