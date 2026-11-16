# SANE 1.4.0 M1120 colour-buffer patch

**File:** `m1120-color-buffer.patch`  
**Applies to:** `backend/hpljm1005.c` from upstream SANE 1.4.0.

Original `hpljm1005.c` is copyright (C) 2007–2008 Philippe Rétornaz and other SANE contributors, licensed GNU GPL version 2 or later with the SANE linking exception. The patch retains compatible terms. See [SANE licensing](https://sane-project.org/license.html).

## What changes

On an HP LaserJet M1120 MFP (USB ID `03f0:5617`), the original 1.4.0 backend hit its `buffer overflow` check in colour mode after several image data chunks. This patch grows the relevant colour-channel buffer using `realloc` when incoming data exceeds the existing capacity. It retains allocation-failure and integer-overflow checks.

Locally tested colour modes: 75, 150, 300 and 600 DPI. **1200 DPI stalled and is not supported.** This experimental patch has not undergone upstream review or testing on other systems.

Use `zsh scripts/build-patched-sane.command` from the repository root to download and verify SANE 1.4.0, apply the patch and build an isolated installation under `~/m1120-sane-test/install`. The original Homebrew SANE remains untouched.
