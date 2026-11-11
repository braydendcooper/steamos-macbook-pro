#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 022

phase() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $(uname -m) == aarch64 ]] || die "Run in the native arm64 build container"
for tool in git cargo make python3 readelf pkg-config tar zstd nproc; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
OUT=${OUT:-/src/aurora/audio-out}
OUT=$(realpath -m -- "$OUT")
# Only these generated children are removed; never clean the mounted checkout.
[[ "$OUT" != / && "$OUT" != /src && "$OUT" != /src/aurora \
   && "$OUT" != /work && "$OUT" != /work/* ]] || die "Unsafe output directory: $OUT"
mkdir -p "$OUT"
archive="$OUT/aurora-audio-steamos-aarch64.tar.zst"
rm -f -- "$archive"
rm -rf -- "$OUT/stage"
mkdir -p "$OUT/stage"
work=$(mktemp -d "$OUT/work.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
stage="$OUT/stage"
packages=(speakerguardd aurora-audio alsa-ucm-conf-aurora bankstown-lv2 triforce-lv2 lsp-plugins-lv2)
for pkg in "${packages[@]}"; do mkdir -p "$stage/$pkg"; done
export CC=${CC:-gcc} CXX=${CXX:-g++}
# Do not inherit the Mesa builder's private libdrm search paths.
unset PKG_CONFIG_PATH LD_LIBRARY_PATH

# Clone without checkout, then detach at a full commit or an explicit tag ref.
# Tag objects may be annotated; HEAD always records the peeled commit.
clone_source() {
    local name=$1 url=$2 ref=$3 expected=$4 resolved
    git clone --no-checkout "$url" "$work/$name"
    git -C "$work/$name" checkout --detach "$ref"
    resolved=$(git -C "$work/$name" rev-parse HEAD)
    [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || die "$name: invalid resolved commit: $resolved"
    printf '%s: %s -> %s\n' "$name" "$ref" "$resolved"
    [[ -z "$expected" || "$resolved" == "$expected" ]] \
        || die "$name: expected $expected, found $resolved"
}

phase "Clone and verify source pins"
clone_source speakerguardd https://github.com/aurora-silicon/speakerguardd.git \
    d1bc5a02752ac01daa52d5ecb84008d7b50caef3 d1bc5a02752ac01daa52d5ecb84008d7b50caef3
clone_source asahi-audio https://github.com/aurora-silicon/asahi-audio.git \
    06aec67a8ac866eb5b40f44634652beff454e297 06aec67a8ac866eb5b40f44634652beff454e297
clone_source alsa-ucm-conf https://github.com/aurora-silicon/alsa-ucm-conf-asahi.git \
    b9b2d0c82cbb46025e586b2dc9f2cae644d29999 b9b2d0c82cbb46025e586b2dc9f2cae644d29999
clone_source bankstown https://github.com/chadmed/bankstown.git \
    refs/tags/1.1.0 e9829c9bccf5ed73768135c0ddd506f5a6690f9e
# Neither a branch nor current HEAD is an acceptable substitute for this tag.
git clone --no-checkout https://github.com/chadmed/triforce.git "$work/triforce"
triforce_tag=
for tag in 0.3.2 v0.3.2; do
    if git -C "$work/triforce" show-ref --verify --quiet "refs/tags/$tag"; then
        triforce_tag=$tag
        break
    fi
done
[[ -n "$triforce_tag" ]] || die "Triforce: neither 0.3.2 nor v0.3.2 tag exists"
git -C "$work/triforce" checkout --detach "refs/tags/$triforce_tag"
triforce_commit=$(git -C "$work/triforce" rev-parse HEAD)
[[ "$triforce_commit" =~ ^[0-9a-f]{40}$ ]] || die "Triforce: invalid resolved commit"
printf 'triforce: tag %s -> %s (no independently verified hash supplied)\n' "$triforce_tag" "$triforce_commit"
clone_source lsp-plugins https://github.com/lsp-plugins/lsp-plugins.git \
    refs/tags/1.2.37 5dc3474fa7ff74fa43ae3bb3df5e25f093787c87

phase "Build and stage speakerguardd"
(
    cd "$work/speakerguardd"
    python3 - <<'PY'
from pathlib import Path
p = Path("speakerguardd.service")
s = p.read_text()
old = "ExecStart=/usr/bin/speakerguardd -c /usr/share/speakerguardd --wait-for-card 30"
new = "ExecStart=/usr/bin/speakerguardd -c /usr/share/speakerguardd -C AppleJ700 --wait-for-card 30"
assert s.count(old) == 1, "Pinned speaker unit changed"
p.write_text(s.replace(old, new, 1))
PY
    cargo build --locked --release
    cargo test --locked
    dest="$stage/speakerguardd"
    install -Dm755 target/release/speakerguardd "$dest/usr/bin/speakerguardd"
    install -d "$dest/usr/share"
    cp -a conf "$dest/usr/share/speakerguardd"
    install -Dm644 speakerguardd.service "$dest/usr/lib/systemd/system/speakerguardd.service"
    install -Dm644 95-speakerguardd.rules "$dest/usr/lib/udev/rules.d/95-speakerguardd.rules"
    install -Dm644 LICENSE "$dest/usr/share/licenses/speakerguardd/LICENSE"
)

phase "Stage Aurora audio and ALSA UCM data"
make -C "$work/asahi-audio" install DESTDIR="$stage/aurora-audio" PREFIX=/usr
install -Dm644 "$work/asahi-audio/LICENSE" "$stage/aurora-audio/usr/share/licenses/aurora-audio/LICENSE"
install -d "$stage/alsa-ucm-conf-aurora/usr/share/alsa"
cp -a "$work/alsa-ucm-conf/ucm2" "$stage/alsa-ucm-conf-aurora/usr/share/alsa/"
install -Dm644 "$work/alsa-ucm-conf/LICENSE.asahi" \
    "$stage/alsa-ucm-conf-aurora/usr/share/licenses/alsa-ucm-conf-aurora/LICENSE"

phase "Build and stage Bankstown and Triforce LV2"
for name in bankstown triforce; do
    (
        cd "$work/$name"
        cargo build --locked --release
        make
        make LIBDIR=/usr/lib DESTDIR="$stage/$name-lv2" install
        license_count=0
        while IFS= read -r -d '' license; do
            install -Dm644 "$license" "$stage/$name-lv2/usr/share/licenses/$name-lv2/${license##*/}"
            license_count=$((license_count + 1))
        done < <(find . -maxdepth 1 -type f \
            \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' \) -print0)
        [[ "$license_count" -gt 0 ]] || die "$name checkout has no LICENSE*, LICENCE* or COPYING* files"
    )
done

phase "Build and stage LSP LV2 without UI"
(
    cd "$work/lsp-plugins"
    make config PREFIX=/usr LIBDIR=/usr/lib FEATURES='lv2'
    make fetch
    make -j"$(nproc)"
    make install DESTDIR="$stage/lsp-plugins-lv2"
    license_count=0
    for license in COPYING COPYING.LESSER; do
        [[ -f "$license" ]] || continue
        install -Dm644 "$license" "$stage/lsp-plugins-lv2/usr/share/licenses/lsp-plugins-lv2/$license"
        license_count=$((license_count + 1))
    done
    [[ "$license_count" -gt 0 ]] || die "LSP checkout has neither COPYING nor COPYING.LESSER"
)

phase "Record package provenance and license filenames"
write_info() {
    local pkg=$1 version=$2 source=$3 url=$4
    {
        printf 'pkgname=%s\npkgver=%s\nsource_url=%s\nresolved_commit=%s\n' \
            "$pkg" "$version" "$url" "$(git -C "$work/$source" rev-parse HEAD)"
        [[ "$pkg" != triforce-lv2 ]] || printf 'source_tag=%s\n' "$triforce_tag"
        printf 'source_license_files:\n'
        find "$work/$source" -maxdepth 1 -type f \
            \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' \) -printf '  %f\n' | sort
        printf 'installed_license_files:\n'
        find "$stage/$pkg/usr/share/licenses/$pkg" -type f -printf '  %f\n' | sort
    } > "$stage/$pkg.info"
    cat "$stage/$pkg.info"
}
write_info speakerguardd 0.1.0.aurora3 speakerguardd https://github.com/aurora-silicon/speakerguardd.git
write_info aurora-audio 4.1.aurora3 asahi-audio https://github.com/aurora-silicon/asahi-audio.git
write_info alsa-ucm-conf-aurora 10.aurora3 alsa-ucm-conf https://github.com/aurora-silicon/alsa-ucm-conf-asahi.git
write_info bankstown-lv2 1.1.0 bankstown https://github.com/chadmed/bankstown.git
write_info triforce-lv2 0.3.2 triforce https://github.com/chadmed/triforce.git
write_info lsp-plugins-lv2 1.2.37 lsp-plugins https://github.com/lsp-plugins/lsp-plugins.git

phase "Audit every staged ELF and print graph plugin URI coverage"
python3 - "$stage" <<'PY'
import pathlib
import re
import subprocess
import sys

stage = pathlib.Path(sys.argv[1])
# SteamOS 0.4.5 ships cairo 1.18.0, the same version as noble.
allowed = set("""
libc.so.6 libm.so.6 libgcc_s.so.1 libstdc++.so.6 libasound.so.2
libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-aarch64.so.1 libsndfile.so.1 libcairo.so.2
""".split())
print("NEEDED allowlist:", " ".join(sorted(allowed)))
errors = []
highest = (0, 0)
counts = {}
def readelf(*args):
    return subprocess.check_output(["readelf", *args], text=True)
for path in sorted(stage.rglob("*")):
    if path.is_symlink() or not path.is_file():
        continue
    with path.open("rb") as stream:
        if stream.read(4) != b"\x7fELF":
            continue
    name = str(path.relative_to(stage))
    pkg = path.relative_to(stage).parts[0]
    counts[pkg] = counts.get(pkg, 0) + 1
    if not re.search(r"Machine:\s+AArch64\b", readelf("--file-header", str(path))):
        errors.append(f"{name}: not AArch64")
    dynamic = readelf("--dynamic", "--wide", str(path))
    libraries = set(re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic))
    print(f"{name}: NEEDED: {' '.join(sorted(libraries)) or '(none)'}")
    for lib in sorted(libraries - allowed):
        errors.append(f"{name}: NEEDED outside allowlist: {lib}")
    if re.search(r"\((?:RPATH|RUNPATH)\)", dynamic):
        errors.append(f"{name}: unexpected RPATH/RUNPATH")
    info = readelf("--version-info", "--wide", str(path))
    needs = info.split("Version needs section", 1)[1] if "Version needs section" in info else ""
    tokens = set(re.findall(r"\bGLIBC_([0-9]+(?:\.[0-9]+)+|PRIVATE)\b", needs))
    if "PRIVATE" in tokens:
        errors.append(f"{name}: requires GLIBC_PRIVATE")
    numeric = [tuple(map(int, v.split('.'))) for v in tokens if v != "PRIVATE"]
    local = max(numeric, default=(0, 0))
    highest = max(highest, local)
    print(f"{name}: highest GLIBC: {'.'.join(map(str, local)) if numeric else '(none)'}")
    if local > (2, 39):
        errors.append(f"{name}: GLIBC requirement exceeds 2.39")
for pkg in ("speakerguardd", "bankstown-lv2", "triforce-lv2", "lsp-plugins-lv2"):
    if not counts.get(pkg):
        errors.append(f"{pkg}: no ELF installed")
print("Overall highest GLIBC:", '.'.join(map(str, highest)))
for pkg in ("aurora-audio", "alsa-ucm-conf-aurora"):
    print(f"{pkg}: installed paths containing j700 (case-insensitive):")
    paths = [str(p.relative_to(stage / pkg)) for p in (stage / pkg).rglob("*")
             if "j700" in str(p.relative_to(stage / pkg)).lower()]
    print('\n'.join(sorted(paths)) or "  (none; inspect upstream install manifest)")
# Scan configuration/graphs, including those under share/asahi-audio. This is
# textual URI coverage, not a substitute for loading graphs in PipeWire.
uris = set()
for pkg in ("aurora-audio", "alsa-ucm-conf-aurora"):
    for path in (stage / pkg).rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        relative = str(path.relative_to(stage / pkg)).lower()
        if not any(key in relative for key in ("pipewire", "wireplumber", "graph")):
            continue
        text = path.read_text(errors="replace")
        uris.update(re.findall(r'http://[^\s<>"\'\\)\]},;]+', text))
bundles = []
for pkg in ("bankstown-lv2", "triforce-lv2", "lsp-plugins-lv2"):
    root = stage / pkg / "usr/lib/lv2"
    found = sorted(root.glob("*.lv2"))
    if not found:
        errors.append(f"{pkg}: no bundle under /usr/lib/lv2")
    for bundle in found:
        ttl = '\n'.join(p.read_text(errors="replace") for p in bundle.rglob("*.ttl"))
        bundles.append((str(bundle.relative_to(stage)), ttl))
print("Unique graph/config HTTP plugin URIs (textual scan):")
for uri in sorted(uris):
    matches = [name for name, ttl in bundles if f"<{uri}>" in ttl]
    print(f"  {uri}: {', '.join(matches) if matches else 'WARNING: no staged LV2 bundle advertises this URI'}")
if not uris:
    print("  WARNING: no HTTP plugin URIs found; inspect installed graphs manually")
if errors:
    sys.exit("ERROR: Runtime audit failed:\n" + '\n'.join(errors))
PY

phase "Archive stage trees and provenance"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$OUT" -cf - stage \
    | zstd -T1 -19 -o "$archive"
du -sh "$stage"/* "$archive"
phase "Done: $archive"
