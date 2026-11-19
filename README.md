# unixnu-sagit-build

GitHub Actions 构建仓库：为小米 6（sagit, MSM8998）编译 UniXNU 启动镜像
`boot-sagit.img`，供 `fastboot boot` 内存引导验证。

依赖的仓库（由 workflow 检出，固定在各自分支）：

| 仓库 | 路径 | 分支 |
|---|---|---|
| [UniXNU/UniXNU](https://github.com/UniXNU/UniXNU) | unixnu-src | main |
| [ilertnost/unixnu-sagit](https://github.com/ilertnost/unixnu-sagit) | unixnu-sagit | main |
| [edk2-porting/edk2-msm8998](https://github.com/edk2-porting/edk2-msm8998) | edk2-msm8998 | new |

## 用法

1. 仓库页面 → Actions → `build-sagit` → Run workflow
2. 首次运行会编译 UniXNU Linux 工具链（LLVM/clang，约 2-4 小时）并缓存到
   GitHub cache（key `unixnu-toolchain-v1`），后续运行直接复用
3. 构建产物下载：run 页面 → Artifacts → `boot-sagit`

## 产物

- `edk2-msm8998/workspace/out/boot-sagit.img` — EDK2 UEFI 固件 + 设备树 + payload，
  打包为 Android boot image v1
- `unixnu-sagit/out/sagit-payload-volume.img[.lzma]` — 44MiB FAT 卷（ADRENOLINE），
  内含 unixnu.toml、kernel.macho、kernel.macho.adt

## 在小米 6 上验证（不写入分区）

```bat
adb reboot bootloader
fastboot boot boot-sagit.img
```

观察屏幕上的 UniXNU 菜单 → DarwinBoot → XNU 引导梯子输出。

## 输入锁定

- IPSW：iPhone10,1 16.7.16 20H392（iPhone_4.7_P3_16.7.16_20H392_Restore.ipsw）
  sha256 `601cb23e740dacf8b61271fe02ffd5b3c146b518abb5a6e6b286e5f0475fe43b`
- OS profile：ios-16.7.16-20H392（XNU 8796.141.3）
- 交叉工具链：arm-gnu-toolchain-13.2.Rel1（aarch64-none-linux-gnu）
- 平台种子 unique-chip-id：0x80150001A7FEC139（A11 + 设备序列号派生）
