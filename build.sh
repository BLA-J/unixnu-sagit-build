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
export DEBIAN_FRONTEND=noninteractive
APT_OK=0
for attempt in 1 2 3 4 5; do
  sudo apt-get update -qq &&
  sudo apt-get install -y --no-install-recommends \
    git patch flex bison bzip2 cpio rsync curl wget ca-certificates tcsh unifdef \
    cmake clang lld mtools gettext \
    build-essential pkg-config ninja-build python3 python3-dev xz-utils \
    libssl-dev zlib1g-dev libbsd-dev uuid-dev llvm-dev libclang-dev device-tree-compiler && APT_OK=1 && break
  echo "apt attempt $attempt failed (mirror error); retrying in 20s"
  sleep 20
done
[ "$APT_OK" = 1 ] || { echo "apt install failed after 5 attempts" >&2; exit 1; }

echo "== install OS profile into UniXNU =="
mkdir -p "$ROOT/unixnu-src/profiles/os"
rm -rf "$ROOT/unixnu-src/profiles/os/ios-16.7.16-20H392"
cp -a "$ROOT/unixnu-sagit/profiles/os/ios-16.7.16-20H392" "$ROOT/unixnu-src/profiles/os/"
# Upstream profile typo: chip_id 32785 (0x8011) is not A11. The 20H392
# BuildManifest carries ApChipID 0x8015 = 32789; without the fix the IPSW
# identity lookup fails with "no Erase build identity for d20ap".
sed -i 's/"chip_id" = 32785/"chip_id" = 32789/' \
  "$ROOT/unixnu-src/profiles/os/ios-16.7.16-20H392/profile.toml"
# The upstream kernel build takes the deployment target from the profile's
# ios_version; the device profile predates that key (it carries sdk/target).
sed -i 's/^"sdk" = "16.0"$/"sdk" = "16.0"\n"ios_version" = "16.0"/' \
  "$ROOT/unixnu-src/profiles/os/ios-16.7.16-20H392/profile.toml"

echo "== rebased driver patches for pinned UniXNU =="
if ! grep -q 'A source-only board has no \[kernel.prelink\]' "$ROOT/unixnu-src/scripts/unixnu/cli.py"; then
  git -C "$ROOT/unixnu-src" apply "$ROOT/rebased/01-driver-edits.patch"
  echo "applied 01-driver-edits.patch"
else
  echo "01-driver-edits.patch already present"
fi
if ! grep -q 'occupied coalesced span' "$ROOT/unixnu-src/kits/XnuPrelink/emit_prelink.py"; then
  git -C "$ROOT/unixnu-src/kits/XnuPrelink" apply \
    "$ROOT/unixnu-sagit/patches/0026-unixnu-prelink-span-shrink.patch"
  echo "applied 0026 span shrink"
else
  echo "0026 span shrink already present"
fi
# The device build script still carries two driver patches that upstream has
# superseded: 0018 (the archive builders now take the deployment target from
# kernel_target.py) and 0027 (the RamDiskDxe now expands UNXNFAT1 chunks, not
# LZMA-alone). Its own guards cannot see that, so drop the two blocks here.
python3 - "$ROOT/unixnu-sagit/tools/build-xnu-sagit.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
for marker, replacement in (
    ('''if ! grep -q "DEPLOYMENT_TARGET = os.environ" "$SRC/scripts/build-libpthread-kernel.py"; then
  git -C "$SRC" apply "$PATCHES/0018-unixnu-archive-deployment.patch"
fi''', '# 0018 superseded: upstream kernel_target.py takes the deployment target from the profile.'),
    ('''if ! grep -q "ExpandLzmaPayload" "$SRC/package/UniXNUPkg/Driver/UniXNURamDiskDxe/UniXNURamDiskDxe.c"; then
  git -C "$SRC" apply "$PATCHES/0027-unixnu-ramdisk-lzma.patch"
fi''', '# 0027 superseded: the upstream RamDiskDxe expands UNXNFAT1 chunks.'),
):
    if marker in text:
        text = text.replace(marker, replacement)
    else:
        raise SystemExit(f'block not found for: {replacement}')
open(path, 'w').write(text)
print('build-xnu-sagit.sh: obsolete patch blocks dropped')
PY

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
  --args="-v -enable_kprintf_spam debug=0x14e"
# The current UniXNURamDiskDxe expands the upstream UNXNFAT1 chunk format
# (1 MiB Tiano-compressed UEFI chunks) instead of the old LZMA-alone wrap.
echo "== UNXNFAT1 ramdisk =="
make -C "$ROOT/edk2-msm8998/Common/edk2/BaseTools" -j"$JOBS" >/dev/null
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'unixnu-src' / 'scripts'))
from unixnu import ramdisk
ramdisk.encode(root / 'unixnu-sagit' / 'out' / 'sagit-payload-volume.img',
               root / 'unixnu-sagit' / 'out' / 'sagit-payload-volume.ramdisk',
               root / 'edk2-msm8998' / 'Common' / 'edk2')
print('ramdisk: packed UNXNFAT1')
PY
ls -l out/sagit-payload-volume.img out/sagit-payload-volume.ramdisk

echo "== EDK2 firmware + boot-sagit.img =="
PAYLOAD="$ROOT/unixnu-sagit/out/sagit-payload-volume.ramdisk" \
ROOT="$ROOT/edk2-msm8998" \
TOOLCHAIN="$ROOT/$GCC_TAR" \
UNIXNU_SRC="$ROOT/unixnu-src" \
  "$ROOT/unixnu-sagit/tools/build-sagit-edk2.sh"

echo "== artifact =="
ls -la "$ROOT/edk2-msm8998/workspace/out/boot-sagit.img"
sha256sum "$ROOT/edk2-msm8998/workspace/out/boot-sagit.img"
