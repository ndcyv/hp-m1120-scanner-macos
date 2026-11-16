# HP LaserJet M1120 MFP Scanner for macOS

A small **native macOS scanner application** for the legacy **HP LaserJet M1120 MFP** (USB). It combines a locally built, patched [SANE](https://sane-project.org/) `hpljm1005` scanner backend with a Swift/AppKit interface. The patch resolves a reproducible colour-scanning buffer overflow observed with this device on macOS 27.

**Status: experimental, community project; not affiliated with or endorsed by HP or Apple.** The application was tested on **one Apple Silicon iMac running macOS 27**. Other Macs, macOS versions, USB adapters, and scanners have not been verified. The app is built locally, not distributed as a signed/notarized binary.

## Features

- Grayscale and colour scanning at **150, 200, 300, or 600 DPI**
- A4, A5, Letter, small (100 × 150 mm), and full-glass scan areas
- PDF, PNG and JPEG for single pages
- Multipage PDF: scan pages one by one, then combine them
- Optional **searchable PDFs** using macOS Vision OCR, entirely offline
- Native AppKit user interface; choose the destination folder
- A built-in application icon

**1200 DPI is intentionally disabled** because it stalled during testing. Do not assume support for other HP models. The printer function needs its **own separate printing driver**; this project only addresses scanning.

## Requirements

- Apple Silicon Mac (the only architecture tested); macOS 27 tested
- HP LaserJet M1120 MFP connected by USB and powered on (USB ID `03f0:5617`)
- [Homebrew](https://brew.sh/) and Apple Command Line Tools (`xcode-select --install`)
- Homebrew packages: SANE, pkgconf, and ImageMagick
- Internet connection **for initial downloads/build only**; the app performs OCR locally, without a cloud service

This build targets macOS 13.0 for compilation, but that **does not imply the app has been tested** on macOS 13 through 26.

## Installation from source

Download or clone this repository, and open Terminal in its folder. Install the requirements first:

```bash
xcode-select --install  # only if Command Line Tools are not already present
brew install sane-backends pkgconf imagemagick
```

Build SANE 1.4.0 with the colour-buffer patch in **your home folder**, without modifying the Homebrew installation:

```bash
zsh scripts/build-patched-sane.command
```

Then build and install the AppKit application:

```bash
zsh install.command
```

The application is installed at **`~/Applications/M1120 Scanner.app`**. Launch it using Finder or:

```bash
open "$HOME/Applications/M1120 Scanner.app"
```

The installer intentionally depends on the patched executable at `~/m1120-sane-test/install/bin/scanimage`. Keep that directory after installation. The installer will replace an existing **M1120 Scanner** app only after compiling its replacement; it does not change HP printing drivers or Homebrew's SANE installation.

If the patched SANE executable is already present and working, **skip the SANE build step**. Installing this project is not necessary on a Mac where its existing app already works.

### What the SANE build script does

It downloads the **official SANE 1.4.0 source archive**, verifies the pinned SHA-256 checksum, applies `patches/m1120-color-buffer.patch` using `patch --dry-run` before actually patching, and compiles an isolated SANE installation under `~/m1120-sane-test/install`. It does **not** run `sudo` or replace Homebrew files. If the target installation already exists, it stops instead of overwriting it.

### Everyday use

For office documents, choose **A4 / Grayscale / 300 DPI / Searchable PDF**. For multiple sheets, check *Combine multiple sheets into one PDF*, scan each sheet in turn, then click *Save PDF*. For a single-page image, choose PNG or JPEG. OCR works with PDFs only and is not perfect on handwriting or damaged originals.

## Tested results

| Scenario | Result on the test Mac |
| --- | --- |
| `scanimage -L` detects M1120 | Passed |
| Original SANE 1.4.0 grayscale | Passed |
| Original SANE 1.4.0 colour | **Failed** (`buffer overflow` / I/O error) |
| Patched colour at 75, 150, 300, 600 DPI | Passed |
| Patched colour at 1200 DPI | **Stalled**, excluded from GUI |
| Native AppKit GUI | Passed |
| Multipage PDF and searchable OCR | Passed in local user testing |

Original error signature:

```text
[hpljm1005] Got data size 1280 ... Scan width: 152, data width: 160
[hpljm1005] buffer overflow
scanimage: sane_read: Error during device I/O
```

The patch grows the per-channel buffer when necessary while retaining allocation-failure handling. It is a **workaround, not an upstream-reviewed or broadly validated fix**. Further USB problems and hangs are possible. If `scanimage` stalls, stop only the scan process, power-cycle the scanner if needed, and do not repeatedly retry 1200 DPI.

## Troubleshooting

**Scanner not detected:** Confirm power and a USB connection; run `~/m1120-sane-test/install/bin/scanimage -L`. Device bus numbers may change on reconnect.

**`PNG support not compiled in`:** The isolated SANE build may not have PNG support. The **app works around this** by requesting PNM and converting it with ImageMagick.

**App compilation complains about `SwiftUIMacros`:** This project uses **AppKit**, not SwiftUI; check that you are installing this release, not the earlier experimental SwiftUI prototype.

**Colour scan hangs:** Terminate `scanimage`, reconnect and power-cycle the scanner. Do not uninstall the system printing driver. If reporting a bug, include macOS, architecture, the command, and a **redacted** error log, not private scanned documents.

**OCR inaccurate:** Try 300 DPI grayscale for crisp documents; handwriting, low contrast, and some languages may produce imperfect results.

## Project structure

```text
M1120Scanner.swift                  AppKit GUI, multipage PDF and local Vision OCR
M1120Scanner.icns / .png             Built-in app icon
install.command                     Compiles and installs the app locally
scripts/build-patched-sane.command  Builds isolated patched SANE 1.4.0
patches/m1120-color-buffer.patch    Small hpljm1005 backend change
patches/README.md                   Patch licensing and technical notes
LICENSE                              MIT license for original app code/scripts
THIRD_PARTY_NOTICES.md              Attribution and dependency information
```

## Licenses and credits

Original scanner app code and helper scripts in this repository are offered under the **MIT License** (`LICENSE`). The SANE backend patch is a modification of GPL-licensed code and is distributed separately under **GPL-2.0-or-later with the SANE linking exception**; see [`patches/README.md`](patches/README.md). SANE 1.4.0 source is **not** redistributed in this repository; the build script retrieves it from the original source archive and verifies its checksum. ImageMagick, Homebrew, and macOS frameworks are separate dependencies. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Community testing and improvements are welcome, especially reports on other macOS versions or M1120 variants. Please avoid posting personal scans, names, email addresses, or unredacted home paths in issues.