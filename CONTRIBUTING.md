# Contributing

Thanks for helping preserve scanner support for older equipment.

Please open an issue before proposing broad architectural changes. Reports about other macOS versions, different USB adapters, and other SANE-compatible devices are welcome.

When reporting a scanning issue, include:
- macOS version and Mac architecture
- Scanner model and USB identifier
- SANE and libusb versions
- Scan mode, DPI and paper size
- Sanitized stderr/debug messages and reproduction steps

Do **not** upload scanned documents containing personal information, passwords, or full home-directory paths. Use a nonsensitive test page instead.

Contributions to the AppKit application and build scripts follow the MIT license. Changes derived from the SANE backend must preserve its GPL-2.0-or-later licensing with the SANE linking exception.

The project is experimental and has no warranty. A scanner hang may require terminating the scan and power-cycling the device.
