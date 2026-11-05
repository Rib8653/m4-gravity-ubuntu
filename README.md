# m4-gravity-ubuntu

Ubuntu 26.04 LTS for the **Apple M4 Mac mini** (`Mac16,10`, `j773g`), built on
[Gravity Linux](https://github.com/GravityLinux)'s M4 hardware enablement.

Gravity Linux is a Fedora 44 remix, forked from Asahi Linux, and the first
distribution to boot the M4 Mac mini with accelerated graphics. This
repository takes Gravity's pinned M4 components and builds them as
Ubuntu `.deb` packages. It then assembles an Ubuntu image that **Gravity's own
macOS installer** can install, unchanged.

> **Status: experimental and untested on hardware.** Gravity itself is an
> early alpha for testing, not for daily use. This port has had build and unit
> testing only (see [Validation](#validation)). Expect rough edges, and keep
> macOS on the machine. Suspend is disabled on purpose, as in Gravity.
> This is an unofficial community build; Canonical and the Gravity Linux
> project do not endorse it.

## What is built

| Component | Source (pinned in `config/sources.env`) | Ubuntu package |
| --- | --- | --- |
| Kernel 7.1.13, 16K pages, M4 GPU (`DRM_ASAHI_M4`), protected J773g speakers | `GravityLinux/linux` + Gravity's config fragments and export patches | `linux-image-7.1.13-gravity-16k`, `linux-headers-…`, `linux-image-gravity-16k` (meta) |
| Mesa 26.3-devel with the Apple9 (M4) Asahi driver | `GravityLinux/mesa`, built with **Ubuntu's own** mesa packaging | Ubuntu's Mesa package names, version `26.3.0~devel-0gravity1` |
| m1n1 bootloader, stage 1 + 2, `NO_DISPLAY` M4 patch, Gravity logo | `GravityLinux/bootloader` + `artwork` | `gravity-bootloader` |
| U-Boot 2026.07 `apple_m1` with Gravity's 58-patch stack | denx.de tarball (or the identical git tag) + `GravityLinux/packages` | `u-boot-gravity-apple` |
| `update-m1n1`, `gravity-fwupdate`, `gravity-diagnose` | `GravityLinux/scripts` | `gravity-ubuntu-platform` |
| Vendor firmware extraction (`gravity-fwextract`) | `GravityLinux/installer` | `gravity-firmware-tools` |
| Temporary no-sleep policy | `GravityLinux/packages` (gravity-remix-scripts) | `gravity-sleep-policy` |
| ALSA UCM profiles | `AsahiLinux/alsa-ucm-conf-asahi` v10 | `alsa-ucm-conf-asahi` |

Everything else (the desktop, systemd, GRUB, shim, PipeWire and so on) is stock
Ubuntu 26.04 from `ports.ubuntu.com`.

### What changes from Fedora to Ubuntu

Gravity's packaging assumes Fedora. This port replaces those Fedora parts:

| Gravity / Fedora | This port / Ubuntu |
| --- | --- |
| dracut modules `91kernel-modules-gravity`, `99gravity-firmware` | **Same modules, unchanged.** Ubuntu 26.04 also defaults to dracut. For systems that switch to initramfs-tools, equivalent hooks are included ([platform/initramfs-tools](platform/initramfs-tools)) |
| kernel-install plugin `15-update-m1n1.install`, DTBs in `/boot/dtb` | `/etc/kernel/postinst.d/zz-update-m1n1` → [`gravity-update-boot`](platform/sbin/gravity-update-boot); DTBs read from `/usr/lib/linux-image-<ver>` |
| SELinux | AppArmor (`kernel/ubuntu.config`) |
| btrfs root with subvolumes, zram | ext4 root (grown on first boot with `x-systemd.growfs`), swap file plus zswap |
| KIWI image build | `mmdebstrap` plus `mke2fs -d` (no loop devices) |
| `plasma-setup` | GNOME: `gnome-initial-setup`; Kubuntu and server: a console first-boot account wizard |
| COPR repository, RPM pins | local apt repository during the build; `apt-mark hold`, or `GRAVITY_APT_URL` with an origin pin |

**DTB location:** Ubuntu's GRUB adds a `devicetree` line whenever `/boot/dtb` or
`/boot/dtb-<version>` exists. That would replace the live device tree that
m1n1 builds and break the boot. So DTBs never go in `/boot`.
`gravity-update-boot` refuses to run if they are there, and `flash-kernel` is
pinned out.

## Boot chain

```
macOS boot picker
  └─ m1n1 stage 1 (installed by Gravity's installer into the APFS stub)
       └─ ESP:/m1n1/boot.bin = m1n1 stage 2 + t8132-j773g.dtb + U-Boot   ← update-m1n1
            └─ U-Boot (UEFI)
                 └─ ESP:/EFI/BOOT/BOOTAA64.EFI (shim) → grubaa64.efi
                      └─ /boot/grub/grub.cfg → vmlinuz + initrd (ext4 /boot)
                           └─ initramfs loads vendor firmware from ESP:/vendorfw
                                └─ Ubuntu (ext4 /)
```

## Building

The build runs best on an **arm64** Linux machine running Ubuntu 26.04: an
Ubuntu VM on the Mac mini itself, an arm64 cloud server, or a GitHub
`ubuntu-24.04-arm` runner. x86_64 also works: the kernel, U-Boot and m1n1
cross-compile, and Mesa and the image build run under qemu-user, which is much slower.

```sh
docker build -t gravity-ubuntu-builder docker/
docker run --rm -it --privileged -v "$PWD:/src" -w /src gravity-ubuntu-builder bash

make sources          # fetch the pinned inputs
make debs             # kernel, bootloader, uboot, mesa, platform -> out/debs/
sudo make image FLAVOR=ubuntu          # or kubuntu, server -> out/image-<flavor>/
make installer FLAVORS="ubuntu kubuntu" BASE_URL=https://you.example/gravity-ubuntu
```

Or build the pieces one at a time with `make kernel`, `make bootloader`,
`make uboot`, `make mesa` and `make platform`. Run `make check` for the lint
and unit tests.

Notes:

* **Kernel base config.** Gravity derives its config from the Asahi Fedora
  16K config in a pinned SRPM (`KERNEL_BASE_SRPM_*`). The build downloads it
  and checks its SHA-256. If `download.copr.fedorainfracloud.org` is
  unreachable, pass the config yourself:
  `KERNEL_BASE_CONFIG=/path/kernel-aarch64-16k-fedora.config make kernel`.
  The build then applies Gravity's `gravity-aarch64.config`, `gravity.config`
  and `gravity-trim.config`, then [`kernel/ubuntu.config`](kernel/ubuntu.config).
  It fails if any line of [`kernel/required.config`](kernel/required.config) is
  missing; Rust support is the usual cause. You need rustc 1.85 or newer and
  bindgen 0.71.1 or newer (Ubuntu 26.04 has 1.93 and 0.72.1).
* **Mesa** builds natively on arm64 (or in an arm64 container). Ubuntu's
  packaging targets Mesa 26.0. Debian patches that no longer apply are dropped
  and named in the log. If file lists have changed, add fixed files under
  [`mesa/debian-overrides/`](mesa/debian-overrides). Without Gravity's Mesa the image falls back to Ubuntu's Mesa,
  which probably has no M4 support, and the build warns you.
* **m1n1** needs the `aarch64-unknown-none-softfloat` Rust target from rustup
  (the Dockerfile installs it). Cargo downloads its two crates using
  upstream's `Cargo.lock`.
* To pick up a new Gravity release, update `GRAVITY_PACKAGES_REF` and copy
  the refs from that revision's `sources.json` into `config/sources.env`.

## Installing on the Mac mini

1. Upload `out/installer/` (`installer_data.json`, `os/*.zip`,
   `bootstrap-ubuntu.sh`, `SHA256SUMS`) to `BASE_URL`.
2. On the Mac, in macOS 26.6.2 (the firmware version Gravity supports), run:

   ```sh
   curl -fsSL https://you.example/gravity-ubuntu/bootstrap-ubuntu.sh | sh
   ```

   This runs **Gravity's installer** (`INSTALLER_BASE`, which defaults to
   Gravity's CDN), but with this repository's `installer_data.json`. It
   creates the APFS stub and installs m1n1 stage 1. It writes the ESP, `/boot`
   and `/` partitions, and copies the Wi-Fi and Bluetooth firmware from macOS.
   The installer must include GravityLinux/installer commit `6420623`, which
   handles the "Linux Filesystem" partition type.
3. Follow the installer's instructions to approve the boot policy in
   recoveryOS, then boot Ubuntu from the startup disk picker.
4. First boot:
   * `/` grows to fill its partition;
   * an 8 GiB swap file is created, with zswap;
   * `gravity-firstboot-grub` runs `grub-install --no-nvram` and `update-grub`,
     so that later GRUB updates work;
   * you create a user: through GNOME Initial Setup (`ubuntu`) or a console
     prompt on tty1 (`kubuntu`, `server`).

Afterwards, kernel updates refresh `m1n1/boot.bin` through the
`zz-update-m1n1` hook. To re-extract the firmware, run `sudo gravity-fwupdate`.
For a bug report, run `gravity-diagnose`.

### Package updates

Without a hosted repository, the image holds the Gravity-built packages
(`apt-mark hold`), so a routine Ubuntu update cannot replace the M4 kernel or
Mesa. To ship updates, host `out/debs` as a flat apt repository and build
images with `GRAVITY_APT_URL=https://…/debs`. Its packages are then pinned
above Ubuntu's.

## Validation

What was done while building this port (November 2026):

* `make check`: shellcheck, shell syntax and unit tests for config overlay
  rules, `gravity-update-boot` (choosing the DTB, rejecting `/boot/dtb`) and
  the `installer_data.json`/zip layout against the installer's size parser.
* U-Boot: all 58 patches in Gravity's spec apply with zero fuzz to v2026.07,
  and `apple_m1` cross-compiles.
* m1n1: stage 1 and stage 2 build with the M4 patch and the logo payload. That
  local build substituted Ubuntu's packaged crates, because crates.io was
  unreachable there.
* Kernel: the Gravity and Ubuntu fragments pass `olddefconfig` with every M4
  option kept, using Ubuntu 26.04's rustc 1.93 and bindgen 0.72.1. That run
  used a stand-in 16K Asahi config, because the Fedora SRPM host was
  unreachable. See the commit log for full-build results.

**Not validated: booting on an M4 Mac mini.** Report results in the issues.

## Credits

All the hard work is Gravity Linux's (Cody Ho, Niklas Sheth and contributors)
and the Asahi Linux project's. The installer, scripts and firmware tools are
MIT. The Gravity artwork used for the m1n1 boot logo is CC-BY-4.0 and subject
to Gravity's trademark policy. "Ubuntu" is a trademark of Canonical Ltd.; this
is an unofficial build.
