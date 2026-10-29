#!/bin/sh
# Standalone PCSX2 wrapper for the custom ES-DE find rule (es_find_rules.xml).
# Wolf's stock launcher (/Applications/launchers/pcsx2.sh) does not pass
# arguments to the AppImage, so ES-DE cannot pass -batch/%ROM%.
exec /Applications/pcsx2-emu.AppImage --appimage-extract-and-run "$@"
