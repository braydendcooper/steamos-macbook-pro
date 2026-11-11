The static, 16K-safe `userpages` binary is not stored in this package directory.
`build-image.sh` copies it from `USERPAGES_BIN` (default:
`/work/build/aurora/userpages`) into the staged package directory before makepkg.
It comes from linux-aurora's `tools/aurora-userpages` (GPL-2.0-only).
