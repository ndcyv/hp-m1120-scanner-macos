# Third-party components and attribution

This community project is not affiliated with HP, Apple, Homebrew, SANE, or ImageMagick.

## SANE

The scanner backend modified by this project is `backend/hpljm1005.c` from **SANE 1.4.0**. Original copyright (C) 2007–2008 Philippe Rétornaz and other SANE contributors. The upstream file is licensed **GPL-2.0-or-later with the SANE linking exception**. See [SANE licensing](https://sane-project.org/license.html) and the upstream source file. The patch is distributed separately under compatible terms as described in `patches/README.md`.

The build script downloads a pristine SANE source archive and checks its checksum. This repository does not bundle or redistribute SANE executables or full source trees.

## Apple frameworks

The app uses AppKit, Vision, Core Graphics, Core Text, and ImageIO as provided by macOS; those frameworks are not bundled here.

## ImageMagick and Homebrew

The app invokes a separately installed `magick` executable. ImageMagick and Homebrew are third-party software governed by their own licenses.

## Icon

The application icon is drawn locally by `scripts/generate-icon.swift` using AppKit and built into the app at installation. It is an original visual and does not contain HP or Apple branding.
