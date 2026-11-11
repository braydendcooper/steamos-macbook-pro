#!/usr/bin/env bash
# Reconstruct Valve's ARM64 vr rootfs; run in the accompanying Linux container.
set -euo pipefail
export LC_ALL=C

log() { printf '[rootfs] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "Failed at line $LINENO. Cached inputs are retained for the next run."' ERR

bundle_url=https://steamdeck-images.steamos.cloud/vr/20261022.6150929/deckard-stable-20261022.6150929-0.4.5.raucb
store_url=https://steamdeck-images.steamos.cloud/vr/chunks.castr
out=./steamos/rootfs-0.4.5

usage() {
    cat <<'EOF'
Usage: fetch-rootfs.sh [--bundle-url URL] [--store-url URL] [--out DIR]
Reconstruct and verify an ARM64 SteamOS vr rootfs from a public RAUC bundle.
Defaults: Steam Frame stable 0.4.5 (20261022.6150929), output ./steamos/rootfs-0.4.5
Requires Linux, Bash, curl, unsquashfs, desync, and GNU coreutils.
EOF
}

while (($#)); do
    case $1 in
        --bundle-url|--store-url|--out)
            (($# >= 2)) && [[ -n $2 ]] || die 'An option requires a value.'
            case $1 in
                --bundle-url) bundle_url=$2 ;;
                --store-url) store_url=$2 ;;
                --out) out=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die 'Unknown argument; use --help.' ;;
    esac
done
for url in "$bundle_url" "$store_url"; do
    [[ $url == https://* && $url != *[[:space:]]* ]] || die 'Source URLs must be HTTPS URLs without whitespace.'
    case $url in
        https://steamdeck-images.steamos.cloud/*|https://holo-images.steamos.cloud/*) ;;
        *) die 'Source URLs must be on steamdeck-images.steamos.cloud or holo-images.steamos.cloud.' ;;
    esac
done
for tool in curl unsquashfs desync sha256sum stat od head tail awk flock; do
    command -v "$tool" >/dev/null || die "Required tool missing: $tool"
done

mkdir -p -- "$out"
out=$(cd -- "$out" && pwd -P)
# Concurrent runs must not write the same partial download or output image.
exec 9>"$out/.fetch.lock"
flock -n 9 || die 'Another fetch is using this output directory.'
source_key=$(printf '%s' "$bundle_url" | sha256sum)
cache="$out/.cache/${source_key%% *}"
mkdir -p -- "$cache"
cd -- "$cache"

if [[ -f bundle.raucb && -f bundle.sha256 ]]; then
    sha256sum --check --status bundle.sha256 || die 'Cached bundle checksum mismatch; remove the cache directory and retry.'
    log 'Reusing checked bundle.'
else
    log 'Downloading public RAUC bundle (resuming any partial download).'
    curl --fail --location --show-error --silent \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --retry 5 --retry-delay 5 \
        --continue-at - --output bundle.raucb.part "$bundle_url"
    mv -f -- bundle.raucb.part bundle.raucb
    sha256sum bundle.raucb > bundle.sha256.tmp
    mv -f -- bundle.sha256.tmp bundle.sha256
fi

if [[ -f extracted.sha256 ]] && sha256sum --check --status extracted.sha256; then
    log 'Reusing checked manifest and rootfs index.'
else
    # Plain RAUC bundle: squashfs, DER signature, then an 8-byte BE length.
    # Do not hand the signature trailer to unsquashfs. Match Valve's reference
    # by explicitly splitting the squashfs payload at this boundary.
    log 'Splitting RAUC payload and extracting manifest/index.'
    bundle_size=$(stat -c %s bundle.raucb)
    ((bundle_size > 8)) || die 'RAUC bundle is too short.'
    sig_size=$(tail -c 8 bundle.raucb | od -An -t u8 --endian=big | tr -d '[:space:]')
    [[ $sig_size =~ ^[0-9]+$ && ${#sig_size} -le 18 ]] || die 'Invalid RAUC signature length.'
    ((sig_size > 0 && sig_size < bundle_size - 8)) || die 'RAUC signature length is outside the bundle.'
    payload_size=$((bundle_size - sig_size - 8))
    head -c "$payload_size" bundle.raucb > bundle.sqfs.part
    # -cat avoids extracting unrelated bundle contents or needing a mount.
    unsquashfs -cat bundle.sqfs.part manifest.raucm > manifest.raucm.part
    mv -f -- manifest.raucm.part manifest.raucm
fi

# INI parser: exact sections/keys, whitespace and CRLF tolerated, duplicates
# rejected. No manifest text is evaluated as shell code.
manifest_value() {
    awk -v section="$1" -v key="$2" '
        { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
        /^[#;]/ || /^$/ { next }
        /^\[/ { active = ($0 == "[" section "]"); next }
        active {
            pos = index($0, "=")
            if (!pos) next
            name = substr($0, 1, pos - 1); sub(/[ \t]+$/, "", name)
            if (name == key) {
                value = substr($0, pos + 1); sub(/^[ \t]+/, "", value)
                count++; result = value
            }
        }
        END { if (count > 1) exit 2; if (count == 1) print result }
    ' manifest.raucm
}

compatible=$(manifest_value update compatible)
[[ $compatible == steamos-aarch64 ]] || die 'Manifest is not compatible with steamos-aarch64.'
expected_sha=$(manifest_value image.rootfs sha256)
expected_size=$(manifest_value image.rootfs size)
index_name=$(manifest_value image.rootfs filename)
[[ $expected_sha =~ ^[[:xdigit:]]{64}$ ]] || die 'Missing or malformed rootfs SHA-256 in manifest.'
expected_sha=$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')
[[ $expected_size =~ ^[1-9][0-9]*$ && ${#expected_size} -le 18 ]] || die 'Missing or malformed rootfs size in manifest.'
# Valve manifests may name rootfs.img or rootfs.img.caibx for casync images.
[[ -n $index_name ]] || die 'Manifest has no rootfs filename.'
[[ $index_name == *.caibx ]] || index_name+=.caibx
[[ $index_name =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*\.caibx$ ]] || die 'Unsafe or unsupported rootfs index filename.'

if [[ ! -f extracted.sha256 ]] || ! sha256sum --check --status extracted.sha256; then
    unsquashfs -cat bundle.sqfs.part "$index_name" > rootfs.img.caibx.part
    [[ -s rootfs.img.caibx.part ]] || die 'Extracted rootfs index is empty.'
    mv -f -- rootfs.img.caibx.part rootfs.img.caibx
    sha256sum bundle.raucb manifest.raucm rootfs.img.caibx > extracted.sha256.tmp
    mv -f -- extracted.sha256.tmp extracted.sha256
fi
rm -f -- bundle.sqfs.part

verify_image() {
    local image=$1 actual_size actual_sha
    actual_size=$(stat -c %s -- "$image")
    [[ $actual_size == "$expected_size" ]] || die "Rootfs size mismatch: got $actual_size, expected $expected_size bytes."
    actual_sha=$(sha256sum -- "$image")
    actual_sha=${actual_sha%% *}
    [[ $actual_sha == "$expected_sha" ]] || die "Rootfs SHA-256 mismatch: got $actual_sha, expected $expected_sha."
}

if [[ -f $out/rootfs.img ]]; then
    log 'Checking existing rootfs.img against the manifest (including full SHA-256).'
    verify_image "$out/rootfs.img"
else
    rm -f -- "$out/build-info.txt"
    log "Assembling rootfs.img: $expected_size bytes; 16 workers, 10 retries per chunk."
    # Keep incomplete output separate. On interruption, rerun this command;
    # bundle/extraction stages are cached, and desync retries failed requests.
    # Desync may reconstruct the partial image again on a subsequent invocation.
    desync extract -n 16 --error-retry 10 \
        -s "${store_url%/}/" rootfs.img.caibx "$out/rootfs.img.part"
    log 'Verifying reconstructed image size and SHA-256.'
    verify_image "$out/rootfs.img.part"
    mv -f -- "$out/rootfs.img.part" "$out/rootfs.img"
fi

rauc_version=$(manifest_value update version)
rauc_build=$(manifest_value update build)
version=
build_id=$rauc_version
bundle_name=${bundle_url##*/}
bundle_name=${bundle_name%%\?*}
if [[ $bundle_name =~ ^deckard-[^-]+-([0-9]+\.[0-9]+)-(.+)\.raucb$ ]]; then
    build_id=${BASH_REMATCH[1]}
    version=${BASH_REMATCH[2]}
fi
[[ -n $version ]] || die 'Cannot determine SteamOS version from bundle filename.'
[[ -n $build_id ]] || die 'Cannot determine build id from bundle filename or manifest.'
cp -- manifest.raucm "$out/manifest.raucm.tmp"
mv -f -- "$out/manifest.raucm.tmp" "$out/manifest.raucm"
{
    printf 'version=%s\nbuild_id=%s\nsha256=%s\nsize=%s\n' "$version" "$build_id" "$expected_sha" "$expected_size"
    printf 'rauc_version=%s\nrauc_build=%s\n' "$rauc_version" "$rauc_build"
    printf 'bundle_url=%s\nstore_url=%s\n' "$bundle_url" "$store_url"
} > "$out/build-info.txt.tmp"
mv -f -- "$out/build-info.txt.tmp" "$out/build-info.txt"
log "Verified rootfs ready: $out/rootfs.img"
