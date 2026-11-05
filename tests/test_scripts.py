"""Unit tests for the build helpers and the on-device scripts."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

TOP = pathlib.Path(__file__).resolve().parent.parent


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


class OverlayConfigTest(unittest.TestCase):
    def test_overlay_rules(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            (tmp / "base").write_text(
                "CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_C=m\nCONFIG_KEEP=y\n# comment\n")
            (tmp / "f1").write_text("CONFIG_A=n\nCONFIG_B=y\nCONFIG_C=y\n")
            (tmp / "f2").write_text("CONFIG_C=m\n# CONFIG_D is not set\n")
            run([sys.executable, str(TOP / "kernel/overlay-config.py"),
                 str(tmp / "base"), str(tmp / "out"), str(tmp / "f1"), str(tmp / "f2")])
            lines = (tmp / "out").read_text().splitlines()
            self.assertIn("# CONFIG_A is not set", lines)
            self.assertNotIn("CONFIG_A=y", lines)
            self.assertIn("CONFIG_B=y", lines)
            self.assertNotIn("# CONFIG_B is not set", lines)
            self.assertEqual([l for l in lines if "CONFIG_C" in l], ["CONFIG_C=m"])
            self.assertIn("# CONFIG_D is not set", lines)
            self.assertIn("CONFIG_KEEP=y", lines)
            self.assertIn("# comment", lines)

    def test_required_options_are_set_by_fragments(self):
        """Every required option is set by our fragment, or by Gravity's (when fetched)."""
        fragments = [TOP / "kernel/ubuntu.config"]
        pkgs = TOP / "work/src/gravity-packages/kernel"
        if not pkgs.exists():
            self.skipTest("Gravity packaging not fetched (make sources)")
        fragments += [pkgs / "gravity-aarch64.config", pkgs / "gravity.config", pkgs / "gravity-trim.config"]
        text = "\n".join(f.read_text() for f in fragments)
        for line in (TOP / "kernel/required.config").read_text().splitlines():
            if line.startswith("CONFIG_") and line.split("=")[0] in ("CONFIG_DRM_ASAHI_M4",
                    "CONFIG_SND_SOC_APPLE_T8132_SPEAKER", "CONFIG_SND_SOC_TAS2764", "CONFIG_SND_SOC_APPLE_MCA"):
                self.assertIn(line, text)


class UpdateBootTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.fake = self.tmp / "update-m1n1"
        self.fake.write_text("#!/bin/sh\necho \"called $*\"\n")
        self.fake.chmod(0o755)

    def kernel(self, version, dtb=True):
        d = self.tmp / f"usr/lib/linux-image-{version}/apple"
        d.mkdir(parents=True)
        if dtb:
            (d / "t8132-j773g.dtb").write_bytes(b"\xd0\x0d\xfe\xed")

    def update(self, *args):
        env = dict(os.environ, GRAVITY_ROOT=str(self.tmp), UPDATE_M1N1=str(self.fake))
        return subprocess.run([str(TOP / "platform/sbin/gravity-update-boot"), *args],
                              env=env, text=True, capture_output=True)

    def test_picks_newest_kernel_with_m4_dtb(self):
        self.kernel("7.1.9-gravity-16k")
        self.kernel("7.1.13-gravity-16k")
        self.kernel("7.2.0-gravity-16k", dtb=False)
        r = self.update("/target/boot.bin")
        self.assertEqual(r.returncode, 0, r.stderr)
        link = self.tmp / "usr/lib/gravity-boot/dtb"
        self.assertEqual(os.readlink(link), "/usr/lib/linux-image-7.1.13-gravity-16k")
        self.assertIn("called /target/boot.bin", r.stdout)

    def test_no_kernel_is_not_an_error(self):
        r = self.update()
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("called", r.stdout)

    def test_refuses_boot_dtb(self):
        self.kernel("7.1.13-gravity-16k")
        (self.tmp / "boot").mkdir()
        (self.tmp / "boot/dtb-7.1.13-gravity-16k").write_bytes(b"x")
        r = self.update()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("GRUB would load it", r.stderr)


def psize(v):
    """Same parsing as GravityLinux/installer src/util.py psize()."""
    v = v.upper().replace(" ", "")
    base = 1000
    if v[-2] == "I":
        base = 1024
        v = v[:-2] + v[-1]
    for suffix, power in {"TB": 4, "GB": 3, "MB": 2, "KB": 1, "B": 0, "": 0}.items():
        if v.endswith(suffix):
            return int(float(v[:-len(suffix)]) * (base ** power))


class PackageInstallerTest(unittest.TestCase):
    def test_installer_data_and_package(self):
        if not shutil.which("zip"):
            self.skipTest("zip not installed")
        with tempfile.TemporaryDirectory() as tmp:
            out = pathlib.Path(tmp) / "out"
            img = out / "image-ubuntu"
            (img / "esp/m1n1").mkdir(parents=True)
            (img / "esp/m1n1/boot.bin").write_bytes(b"m1n1")
            (img / "esp/EFI/BOOT").mkdir(parents=True)
            (img / "esp/EFI/BOOT/BOOTAA64.EFI").write_bytes(b"MZ")
            (img / "boot.img").write_bytes(b"\0" * 8192)
            (img / "root.img").write_bytes(b"\0" * 16384)
            with open(img / "image.json", "w") as fd:
                json.dump({"ubuntu_release": "26.04", "esp_volume_id": "0x1234abcd",
                           "boot_size": 8192, "root_size": 16384}, fd)
            env = dict(os.environ, OUT=str(out), WORK=str(pathlib.Path(tmp) / "work"),
                       FLAVORS="ubuntu", BASE_URL="https://example.invalid/u", SOURCE_DATE_EPOCH="1790000000")
            run([str(TOP / "scripts/package-installer.sh")], env=env)

            data = json.loads((out / "installer/installer_data.json").read_text())
            (entry,) = data["os_list"]
            self.assertEqual(entry["boot_object"], "m1n1.bin")
            self.assertEqual(entry["next_object"], "m1n1/boot.bin")
            self.assertEqual(entry["supported_fw"], ["26.6.2"])
            esp, boot, root = entry["partitions"]
            self.assertEqual((esp["type"], esp["format"], esp["source"]), ("EFI", "fat", "esp"))
            self.assertTrue(esp["copy_firmware"] and esp["copy_installer_data"])
            self.assertEqual(psize(boot["size"]), 8192)
            self.assertEqual(psize(root["size"]), 16384)
            self.assertTrue(root["expand"])
            self.assertEqual(psize(esp["size"]), 500_000_000)

            pkg = out / "installer/os" / entry["package"]
            with zipfile.ZipFile(pkg) as z:
                names = z.namelist()
                self.assertIn("boot.img", names)
                self.assertIn("root.img", names)
                self.assertIn("esp/m1n1/boot.bin", names)
                self.assertEqual(z.getinfo("root.img").compress_type, zipfile.ZIP_STORED)
                for image in ("boot.img", "root.img"):
                    self.assertEqual(z.getinfo(image).file_size % 4096, 0)

            boot_sh = (out / "installer/bootstrap-ubuntu.sh").read_text()
            self.assertIn("https://example.invalid/u/installer_data.json", boot_sh)
            self.assertNotIn("@BASE_URL@", boot_sh)
            self.assertNotIn("@INSTALLER_BASE@", boot_sh)


class InitramfsHookTest(unittest.TestCase):
    def test_scripts_answer_prereqs(self):
        for rel in ("hooks/gravity", "scripts/init-top/gravity-firmware", "scripts/init-bottom/gravity-firmware"):
            r = run(["sh", str(TOP / "platform/initramfs-tools" / rel), "prereqs"])
            self.assertEqual(r.stdout.strip(), "", rel)


if __name__ == "__main__":
    unittest.main()
