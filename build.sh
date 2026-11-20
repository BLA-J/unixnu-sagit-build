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

echo "== install toolchain shims into /usr/bin =="
# setup-toolchain.py runs in the separate toolchain job on another runner; its
# /usr/bin shims are outside the cached prefix, so install them here again.
for shim in xcrun plutil codesign; do
  sudo install -m 0755 "$ROOT/unixnu-src/scripts/linux/$shim" "/usr/bin/$shim"
done

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
# [os] target now names the OS family (ios/macosx) for UNIXNU_XNU_TARGET; the
# device profile still carries the old triple value there, which the baseline
# script rejects.
sed -i 's/^"target" = "arm64-apple-ios16.0"$/"target" = "ios"/' \
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
# ArmCpu.cpp references arm64_platform_sleep_hook as a weak import: the board
# kernel patch is expected to define the variable in ml_arm_sleep. XNU 8796 has
# no such definition and the kernel link rejects the unresolved weak data
# reference. Platform sleep is not needed for bring-up, so the driver defines
# the hook itself (null unless platform-sleep=1, which we never pass) and the
# now-always-true "&hook" guard goes away (it trips -Werror).
python3 - "$ROOT/unixnu-src/drivers/ArmCpu/ArmCpu.cpp" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = 'extern "C" void (*arm64_platform_sleep_hook) (boolean_t boot_cpu) __attribute__((weak_import));'
new = 'extern "C" void (*arm64_platform_sleep_hook) (boolean_t boot_cpu) = nullptr;'
if old in text:
    text = text.replace(old, new)
if '&arm64_platform_sleep_hook && ' in text:
    text = text.replace('&arm64_platform_sleep_hook && ', '')
if '&arm64_platform_sleep_hook' in text:
    raise SystemExit('ArmCpu.cpp: remaining &arm64_platform_sleep_hook reference')
if new not in text:
    raise SystemExit('ArmCpu.cpp: sleep hook declaration not found')
open(path, 'w').write(text)
print('ArmCpu.cpp: arm64_platform_sleep_hook defined locally, guard dropped')
PY
# The device build script still carries two driver patches that upstream has
# superseded: 0018 (the archive builders now take the deployment target from
# kernel_target.py) and 0027 (the RamDiskDxe now expands UNXNFAT1 chunks, not
# LZMA-alone). Its own guards cannot see that, so drop the two blocks here.
# It also re-copies the stock OS profile over the corrected one just before the
# kernel step, which would undo the chip_id/ios_version/target fixes above; the
# profile is already installed, so its copy block goes away too.
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
    ('''mkdir -p "$SRC/profiles/os"
rm -rf "$SRC/profiles/os/ios-16.7.16-20H392"
cp -a "$DEVICE_DIR/profiles/os/ios-16.7.16-20H392" "$SRC/profiles/os/"''',
     '# The corrected OS profile is installed by the driver script; not re-copied here.'),
):
    if marker in text:
        text = text.replace(marker, replacement)
    else:
        raise SystemExit(f'block not found for: {replacement}')
open(path, 'w').write(text)
print('build-xnu-sagit.sh: obsolete patches and profile overwrite dropped')
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
# GCC 13 enables -Wdangling-pointer by default; the platform deliberately stores
# the address of a local memory-map array in a static (ArmPlatformLibMem.c), and
# RELEASE builds treat warnings as errors. This is the maintainer's 0001 fix.
python3 - "$ROOT/edk2-msm8998/Platforms/Msm8998Pkg/Msm8998.dsc" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if '-Wno-dangling-pointer' in text:
    print('Msm8998.dsc: dangling-pointer already suppressed')
else:
    anchor = '  GCC:RELEASE_*_*_CC_FLAGS  = -DMDEPKG_NDEBUG\n'
    if anchor not in text:
        raise SystemExit('Msm8998.dsc: GCC build-options anchor not found')
    text = text.replace(anchor, anchor + '  GCC:*_*_*_CC_FLAGS = -Wno-dangling-pointer\n', 1)
    open(path, 'w').write(text)
    print('Msm8998.dsc: added -Wno-dangling-pointer for GCC 13')
PY
# The platform has no flash NVRAM region, so VariableRuntimeDxe cannot persist
# Boot####/BootOrder; without them BDS has no UniXNU option and starts the shell.
# RAM-emulated variables are enough: UniXNUDxe re-registers its option on every
# boot (the driver says so explicitly), and the shell is not needed at all.
python3 - "$ROOT/edk2-msm8998/Platforms/Msm8998Pkg/Msm8998.dsc" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'PcdEmuVariableNvModeEnable' in text:
    print('Msm8998.dsc: emulated variables already enabled')
else:
    anchor = '  gArmTokenSpaceGuid.PcdSystemMemorySize|0xF0000000        # System Memory (4GB)\n'
    if anchor not in text:
        raise SystemExit('Msm8998.dsc: system-memory PCD anchor not found')
    text = text.replace(
        anchor,
        anchor + '  gEfiMdeModulePkgTokenSpaceGuid.PcdEmuVariableNvModeEnable|TRUE\n'
                 '  gEfiMdeModulePkgTokenSpaceGuid.PcdVariableStoreSize|0x00010000\n',
        1,
    )
    open(path, 'w').write(text)
    print('Msm8998.dsc: RAM-emulated variable store enabled for BDS boot options')
PY
# The device overlay patches the DSC expecting SagitPkg/Drivers/RamDiskDxe and
# the UniXNU module block to be there already (its own anchor check runs before
# it appends them). Wire the platform DSC here first; the overlay then only adds
# ArmPkg.dec visibility and stays idempotent.
DSC="$ROOT/edk2-msm8998/Platforms/Msm8998Pkg/Device/xiaomi/sagit/sagit.dsc"
python3 - "$DSC" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'UniXNUPkg/Driver/UniXNUDxe' in text:
    print('DSC: UniXNU modules already wired')
else:
    if not text.endswith('\n'):
        text += '\n'
    text += '''
#
# UniXNU boot manager + DarwinBoot XNU loader. Both packages live outside this
# tree and are resolved through PACKAGES_PATH (see build-sagit-edk2.sh).
#
[LibraryClasses.common]
  UniXNULib|UniXNUPkg/Library/UniXNULib/UniXNULib.inf

# "common" is a valid tag for LibraryClasses but not for Components: a
# [Components.common] heading is silently skipped, so these modules would never
# be compiled and the firmware would fall through to the shell.
[Components]
  UniXNUPkg/Driver/UniXNUDxe/UniXNUDxe.inf
  # UniXNURamDiskDxe reads a Mu-Silicium SEC HOB this EDK2 port does not
  # create; SagitRamDiskDxe publishes the ramdisk from the device tree instead.
  SagitPkg/Drivers/RamDiskDxe/RamDiskDxe.inf
  SagitPkg/Drivers/ReportDxe/ReportDxe.inf
  UniXNUPkg/Application/UniXNU/UniXNU.inf {
    <LibraryClasses>
      FdtLib|MdePkg/Library/BaseFdtLib/BaseFdtLib.inf
  }
  DarwinBootPkg/Driver/DarwinBoot.inf
  # Debug aid for bring-up: FvSimpleFileSystem exposes firmware-volume files as
  # fsN: so the UniXNU application can be started by hand when BDS does not pick
  # it up. UsbKbDxe is already a prebuilt binary in the platform, not added here.
  MdeModulePkg/Universal/FvSimpleFileSystemDxe/FvSimpleFileSystemDxe.inf
'''
    open(path, 'w').write(text)
    print('DSC: UniXNU/DarwinBoot/Sagit modules appended')
PY
# Same debug module has to be packed into the main firmware volume; the FDF
# anchor is the commented-out KernelFdtDxe line the device overlay uses.
python3 - "$ROOT/edk2-msm8998/Platforms/Msm8998Pkg/Device/xiaomi/sagit/sagit.fdf" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'FvSimpleFileSystemDxe' in text:
    print('FDF: file-system module already present')
else:
    anchor = '  # INF src/kernelfdt/KernelFdtDxe.inf\n'
    if anchor not in text:
        raise SystemExit('FDF: anchor not found')
    text = text.replace(
        anchor,
        anchor + '  INF MdeModulePkg/Universal/FvSimpleFileSystemDxe/FvSimpleFileSystemDxe.inf\n',
        1,
    )
    open(path, 'w').write(text)
    print('FDF: added FvSimpleFileSystemDxe')
PY
# bash expands assignments in order, so capture the paths first: assigning ROOT
# inside the call would make the following "$ROOT/..." expansions point into
# edk2-msm8998 (which is how MU_BASECORE ended up under the EDK2 tree).
EDK2_ROOT="$ROOT/edk2-msm8998"
GCC_DIR="$ROOT/$GCC_TAR"
UNIXNU_DIR="$ROOT/unixnu-src"
# The fetch feed directory carries the source hash of this checkout, not the
# revision the device script was written against (mu_basecore-8f10084c here).
MU_BASECORE_DIR="$(ls -d "$UNIXNU_DIR"/out/feeds/mu_basecore-* 2>/dev/null | head -1)"
[ -d "$MU_BASECORE_DIR/MdePkg" ] || { echo "Mu basecore feed missing under $UNIXNU_DIR/out/feeds" >&2; exit 1; }
echo "Mu basecore: $MU_BASECORE_DIR"
PAYLOAD="$ROOT/unixnu-sagit/out/sagit-payload-volume.ramdisk" \
ROOT="$EDK2_ROOT" \
TOOLCHAIN="$GCC_DIR" \
UNIXNU_SRC="$UNIXNU_DIR" \
MU_BASECORE="$MU_BASECORE_DIR" \
  "$ROOT/unixnu-sagit/tools/build-sagit-edk2.sh"

echo "== artifact =="
ls -la "$ROOT/edk2-msm8998/workspace/out/boot-sagit.img"
sha256sum "$ROOT/edk2-msm8998/workspace/out/boot-sagit.img"
