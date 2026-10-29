#!/bin/sh
# Standalone Dolphin wrapper for the custom ES-DE find rule (es_find_rules.xml).
# Used as the "Dolphin (Standalone)" alt emulator, bypassing the libretro/dolphin
# core, which has a known "target refresh rate" oscillation bug in games that
# switch video mode often (e.g. Mega Man X Collection, whose Capcom-embedded SNES
# emulator switches video mode).
# AppImage kept outside $HOME/bin (that path is blocked for Claude Code for security).
exec /home/retro/dolphin-emu.AppImage --appimage-extract-and-run "$@"
