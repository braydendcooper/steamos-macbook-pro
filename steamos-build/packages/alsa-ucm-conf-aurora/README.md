The prebuilt `alsa-ucm-conf-aurora` payload is not stored in this package directory.
`build-image.sh` copies `stage/alsa-ucm-conf-aurora/` from `AUDIO_TAR` (default:
`/src/aurora/audio-out/aurora-audio-steamos-aarch64.tar.zst`) into the staged
package directory's `stage/` before makepkg. See [audio/README.md](../../audio/README.md)
for source pins, build instructions and audit limits.
