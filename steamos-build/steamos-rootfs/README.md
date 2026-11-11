# Steam Frame ARM64 root filesystem

Reconstructs Valve's SteamOS `vr` rootfs from its public RAUC update bundle
and casync chunk store, following the rootfs step in `fxgl/steamac`.
The default release is **0.4.5**, build **20261022.6150929**, rather than the
old 0.3.0 recovery image. This is a pinned release; the script does not discover
future stable releases automatically.

From the repository's current directory, run:

```sh
docker build --platform linux/arm64 -t steamos-rootfs-fetch steamos-rootfs
docker volume create steamos-build
docker run --rm --platform linux/arm64 \
  --mount type=volume,source=steamos-build,target=/src \
  steamos-rootfs-fetch --out /src/steamos/rootfs-0.4.5
```

Docker needs network access when building and fetching. No privileged container
or filesystem mount is required. The image uses Debian trixie ARM64 and builds
desync from the pinned source release `v1.1.4` using Go.

The named volume contains:

- `/src/steamos/rootfs-0.4.5/rootfs.img`: verified btrfs filesystem image,
  approximately **10 GiB** (10,737,418,240 bytes for a 10 GiB image).
- `/src/steamos/rootfs-0.4.5/manifest.raucm`: the original bundle manifest.
- `/src/steamos/rootfs-0.4.5/build-info.txt`: SteamOS release `version` (e.g.
  `0.4.5`) and `build_id` (e.g. `20261022.6150929`) from the bundle filename,
  raw manifest `[update]` fields `rauc_version` and `rauc_build` (empty allowed),
  SHA-256, exact byte size, and source URLs. If the filename does not match,
  manifest `[update] version` supplies `build_id`; an unknown release `version`
  causes the script to fail.

**Each Neo rootfs slot partition must be at least 10 GiB**, and at least the
manifest's exact image size if a later release grows. Allow additional space in
Docker's volume storage for the downloaded bundle, temporary squashfs payload,
and reconstructed image; 20 GiB free is a useful starting point.

To inspect the receipt:

```sh
docker run --rm --platform linux/arm64 \
  --mount type=volume,source=steamos-build,target=/src \
  --entrypoint cat steamos-rootfs-fetch \
  /src/steamos/rootfs-0.4.5/build-info.txt
```

Override sources and destination with `--bundle-url URL`, `--store-url URL`,
and `--out DIR`. Defaults use Valve's public image host
`https://steamdeck-images.steamos.cloud`; `https://holo-images.steamos.cloud`
serves the same files and is also accepted. For example:

```sh
docker run --rm --platform linux/arm64 \
  --mount type=volume,source=steamos-build,target=/src \
  steamos-rootfs-fetch \
  --bundle-url https://holo-images.steamos.cloud/vr/20261022.6150929/deckard-stable-20261022.6150929-0.4.5.raucb \
  --store-url https://holo-images.steamos.cloud/vr/chunks.castr \
  --out /src/steamos/rootfs-0.4.5
```

Interrupted bundle downloads resume with `curl -C -`. Rerun the same command
to reuse checked inputs in the output directory's `.cache`; completed images
are rechecked for both size and full SHA-256 before being skipped. Chunk
requests use 16 concurrent workers and 10 retries. Interrupted desync extraction
may reconstruct the partial image again; it never publishes a partial image as
`rootfs.img`. An existing final image that mismatches the selected manifest
causes an error: use a separate output directory for a different release, or
move a damaged image aside before retrying. Keep each output directory dedicated
to this script and retain its cache for subsequent runs.

The RAUC trailer is split using its final 8-byte big-endian signature length;
only the manifest and rootfs `.caibx` index are extracted from squashfs. The
manifest must specify `steamos-aarch64`, and the assembled image must match its
rootfs size and SHA-256. Local cache checksums detect changed cached inputs.
This script does **not** authenticate the RAUC CMS signature against a pinned
Valve CA or independently pin the bundle checksum, as the larger reference
project does; verification here establishes consistency with the downloaded
manifest over HTTPS.
