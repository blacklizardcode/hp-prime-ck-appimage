# HP Prime Connectivity Kit as a Linux AppImage

A single file that runs HP's Windows **Connectivity Kit** (2.4.2, 64-bit) on Linux, using a bundled portable Wine.
It doesn't need Wine, winetricks, or 32-bit libraries on your system.

## Install with Gear Lever

[Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) puts AppImages in your app menu and keeps them in one place (`~/AppImages`).

1. **Get the AppImage.** Download `HP_Prime_Connectivity_Kit-2.4.2-x86_64.AppImage` from this repo's **Releases** page, or [build it yourself](#build-it-yourself).

2. **Install Gear Lever** from Flathub, if you don't have it yet:

   ```bash
   flatpak install flathub it.mijorus.gearlever
   ```

3. **Allow USB access to the calculator** (once per computer). This asks for your password and installs a udev rule:

   ```bash
   chmod +x ~/Downloads/HP_Prime_Connectivity_Kit-2.4.2-x86_64.AppImage
   ~/Downloads/HP_Prime_Connectivity_Kit-2.4.2-x86_64.AppImage --setup-usb
   ```

   Unplug and re-plug the calculator afterwards.

4. **Add it to Gear Lever.** Open Gear Lever, drag the AppImage into its window (or open the AppImage with Gear Lever), and choose to move it to the app menu.
   From a terminal you can do the same with:

   ```bash
   flatpak run it.mijorus.gearlever --integrate ~/Downloads/HP_Prime_Connectivity_Kit-2.4.2-x86_64.AppImage
   ```

5. **Start "HP Prime Connectivity Kit"** from your app menu. The first start installs the Connectivity Kit into Wine and takes about a minute. After that it opens directly.

**Updating:** drop a newer AppImage into Gear Lever the same way. On its next start, the existing install upgrades to the new CK version, and your settings and content are kept.

## Options

You can run the AppImage with options from a terminal.
Gear Lever keeps it in `~/AppImages/` (run `ls ~/AppImages` to see the file name).

| Option | What it does |
|---|---|
| `--scale N` | UI size on HiDPI screens, e.g. `2`, `1.5` or `150%`. `--scale auto` (the default) follows your desktop's scaling. |
| `--setup-usb` | Install the udev rule for the HP Prime. |
| `--check-usb` | Check whether a connected calculator is visible and accessible. |
| `--installer FILE` | Install another HP installer into the same Wine prefix, e.g. the HP Prime **Virtual Calculator**. |
| `--reinstall` | Reinstall the bundled Connectivity Kit. |
| `--winecfg` | Open Wine's settings for this prefix. |
| `--wine ARGS` | Run the bundled Wine with ARGS in this prefix. |
| `--reset` | Delete the Wine prefix. This also removes the CK's settings and content stored inside it. |
| `--install-desktop` | Add a menu entry without Gear Lever. |
| `--help` | Show all options. |

* The Wine prefix, where the CK and its data live, is `~/.local/share/hp-prime-ck/prefix`. Set `HPCK_PREFIX` to use a different one.
* The log is `~/.local/share/hp-prime-ck/hpck.log`. For USB debugging, run with `WINEDEBUG=+hid,+hidraw`.
* If the AppImage won't start because of FUSE, run `sudo apt install fuse3`.

## Build it yourself

On Debian or Ubuntu:

```bash
sudo apt install curl xz-utils cabextract msitools p7zip-full python3 file
./build.sh
```

The output is `HP_Prime_Connectivity_Kit-<version>-x86_64.AppImage` (about 195 MB).
Every download is checked against a pinned SHA-256:

| Input | Source |
|---|---|
| Wine 11.0 (amd64-wow64) | [Kron4ek/Wine-Builds](https://github.com/Kron4ek/Wine-Builds) |
| HP Connectivity Kit 2.4.2 x64 | HP's installer, from [hpcalc.org](https://www.hpcalc.org/details/8938) |
| appimagetool | [AppImage/appimagetool](https://github.com/AppImage/appimagetool) |

If you already have an HP installer, use `./build.sh --ck-installer path/to/HP_Prime_Connectivity_Kit_x64_*.exe`.
For a different CK version, also set `CK_SHA256=` (empty) to skip the pinned checksum.

## How it works

* `build.sh` doesn't run HP's installer. HP's `.exe` is a WiX Burn bundle, so the script unpacks it with `cabextract` and keeps only:
  * `VC_redist.x64.exe`, the Microsoft Visual C++ runtime
  * `ConnectivityKit.msi`

  It skips Apple Bonjour, which is only used for network/mDNS discovery and doesn't work well under Wine. The icon comes from the MSI.
* On first launch, `AppRun` does the following:
  1. Creates a 64-bit Wine prefix.
  2. Sets Windows 10 mode and font smoothing.
  3. Sets native-first DLL overrides for the MSVC runtime.
  4. Installs the VC++ runtime silently.
  5. Runs `msiexec /i ConnectivityKit.msi /qn`.
* **Wine fix:** at startup the CK asks Windows for the text scale factor (`IUISettings2::get_TextScaleFactor`).
  In Wine (11.0 up to at least 11.21) that call is a stub that returns `E_NOTIMPL`. The CK then hits an uncaught C++ exception and exits with code 3 before any window appears.
  `patch-windows-ui.py` patches that one stub in the bundled `windows.ui.dll` so it returns `1.0` / `S_OK`.
  `AppRun` copies the patched DLL into the prefix's `system32` on every start.
* USB works through Wine's **hidraw** backend (`winebus.sys`). The calculator is a vendor-defined HID device, so Wine passes it through to the CK if your user can open `/dev/hidraw*`.
  `--setup-usb` installs `/etc/udev/rules.d/70-hp-prime.rules` for `03f0:2441` (Prime G2) and `03f0:0441` / `03f0:1541` (G1).

## Known limitations

* Talking to a **physical** calculator over USB under Wine is reported as working but sometimes glitchy on the HP forum. The user interface, program editing, and the virtual calculator are solid.
  If the calculator connects but its content shows up empty, unplug and re-plug it with the CK open, and make sure the calculator firmware is current.
* x86_64 only.
