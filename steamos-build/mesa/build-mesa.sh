#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 022

phase() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || die "Usage: $0 <mesa-source-dir> <output-dir>"
source_dir=$(realpath -e -- "$1")
output_dir=$(realpath -m -- "$2")
[[ -f "$source_dir/meson.build" ]] || die "Missing $source_dir/meson.build"
# The output contains directories we delete. Reject overlapping source/output.
[[ "$output_dir" != / && "$output_dir" != "$source_dir" \
   && "$output_dir" != "$source_dir/"* && "$source_dir" != "$output_dir/"* ]] \
    || die "Source and output must be separate, non-overlapping directories"
[[ $(uname -m) == aarch64 ]] || die "Run in the native arm64 build container"
for tool in meson ninja python3 readelf pkg-config tar zstd git; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
jobs=${BUILD_JOBS:-$(nproc)}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be a positive integer"
commit=a19691114759e2c0507f3502cf6166ef2c6e2e33

phase "Verify source pin, toolchain and Meson requirement"
[[ $(git -C "$source_dir" rev-parse HEAD) == "$commit" ]] \
    || die "Source must be omacom/mesa at $commit (supply its Git checkout)"
[[ -z $(git -C "$source_dir" status --porcelain --untracked-files=normal) ]] \
    || die "Mesa source checkout must be clean, including untracked files"
python3 - "$source_dir/meson.build" "$(meson --version)" <<'PY'
import re
import sys
from packaging.specifiers import SpecifierSet
from packaging.version import Version
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"\bmeson_version\s*:\s*(['\"])(.*?)\1", text, re.S)
if not match:
    sys.exit("ERROR: Cannot read meson_version from source meson.build; inspect it manually")
requirement = match.group(2).strip()
if not re.match(r"[<>=!~]", requirement):
    requirement = ">=" + requirement
print(f"Source requires Meson {requirement}; installed {sys.argv[2]}")
if Version(sys.argv[2]) not in SpecifierSet(requirement):
    sys.exit("ERROR: Meson pin does not satisfy source; update MESON_VERSION and rebuild image")
PY
pkg-config --atleast-version=2.4.124 libdrm \
    || die "Image must contain private libdrm >=2.4.124 built from /src/deps/libdrm-*.tar.xz"
[[ $(pkg-config --variable=prefix libdrm) == /opt/libdrm ]] \
    || die "Expected private build-time libdrm at /opt/libdrm"
printf 'libdrm: %s\n' "$(pkg-config --modversion libdrm)"
# A newer requirement in Mesa is also checked by meson setup, without fallback
# downloads. Keep generated timestamps stable across repeated builds.
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$source_dir" show -s --format=%ct HEAD)}
export PYTHONHASHSEED=0

phase "Clean build and staging directories"
mkdir -p -- "$output_dir"
tools_dir="$output_dir/build-tools"
build_dir="$output_dir/build"
root="$output_dir/root"
rm -rf -- "$tools_dir" "$build_dir" "$root"
rm -f -- "$output_dir/mesa-aurora-steamos-aarch64.tar.zst" \
    "$output_dir/manifest.txt" "$output_dir/needed.txt" "$output_dir/glibc.txt"
mkdir -p -- "$root"

# Keep the PKGBUILD's supported options. Empty video-codecs/vulkan-layers lists
# disable optional codec/layer dependencies. softpipe needs no LLVM runtime.
common=(
    --prefix=/usr --libdir=lib --libexecdir=lib --sbindir=bin
    --buildtype=release --wrap-mode=nodownload
    -Db_pie=true -Db_ndebug=true
    -Dplatforms=x11,wayland
    -Dgallium-drivers=asahi,zink,softpipe -Dvulkan-drivers=asahi
    -Degl=enabled -Dgbm=enabled -Dglx=dri
    -Dgles1=enabled -Dgles2=enabled -Dglvnd=enabled
    -Dvideo-codecs= -Dvulkan-layers=
    -Dexpat=enabled -Dzstd=enabled -Dlmsensors=enabled
    -Dlibunwind=disabled -Dvalgrind=disabled
    -Dgallium-rusticl=false -Dbuild-tests=false
)

phase "Bootstrap LLVM-backed shader compilers (build tools only)"
meson setup "$tools_dir" "$source_dir" "${common[@]}" -Dllvm=enabled
ninja -C "$tools_dir" -j "$jobs" \
    src/compiler/clc/mesa_clc \
    src/compiler/spirv/vtn_bindgen2 \
    src/asahi/clc/asahi_clc
# Meson native-file strings need quoting independent of shell quoting.
python3 - "$tools_dir" "$output_dir/tools.ini" <<'PY'
import pathlib
import sys
base = pathlib.Path(sys.argv[1])
paths = {
    "mesa_clc": "src/compiler/clc/mesa_clc",
    "vtn_bindgen2": "src/compiler/spirv/vtn_bindgen2",
    "asahi_clc": "src/asahi/clc/asahi_clc",
}
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("[binaries]\n")
    for name, relative in paths.items():
        value = str(base / relative).replace("\\", "\\\\").replace("'", "\\'")
        out.write(f"{name} = '{value}'\n")
PY

phase "Configure and build drivers without runtime LLVM"
meson setup "$build_dir" "$source_dir" "${common[@]}" \
    --native-file "$output_dir/tools.ini" \
    -Dllvm=disabled -Dspirv-tools=disabled \
    -Dmesa-clc=system -Dprecomp-compiler=system
ninja -C "$build_dir" -j "$jobs"

phase "Install into $root"
DESTDIR="$root" meson install -C "$build_dir" --no-rebuild

phase "Check runtime entry points and write manifest"
for entry in usr/lib/libEGL_mesa.so.0 usr/lib/libGLX_mesa.so.0 \
    usr/lib/libgbm.so.1 usr/lib/libvulkan_asahi.so \
    usr/share/glvnd/egl_vendor.d/50_mesa.json \
    usr/share/drirc.d/00-mesa-defaults.conf; do
    [[ -e "$root/$entry" ]] || die "Missing runtime entry point: $entry"
done
compgen -G "$root/usr/lib/dri/*_dri.so" >/dev/null || die "No DRI modules installed"
compgen -G "$root/usr/share/vulkan/icd.d/*asahi*.json" >/dev/null \
    || die "Missing Asahi Vulkan ICD JSON"
(
    cd "$root"
    find . \( -type f -o -type l \) -printf '%P\n' | sort
) > "$output_dir/manifest.txt"

phase "Audit every installed ELF: dependencies, architecture, GLIBC ceiling"
# Do not use ldd: inspecting a staged ELF must not execute it. Read version
# requirements (not exported version definitions), including non-executable .so.
python3 - "$root" "$output_dir" <<'PY'
import os
import pathlib
import re
import subprocess
import sys

root, output = map(pathlib.Path, sys.argv[1:])
highest = (0, 0)
errors = []
elf_count = 0
env = dict(os.environ, LC_ALL="C")
def readelf(*args):
    return subprocess.check_output(["readelf", *args], text=True, env=env)
with (output / "needed.txt").open("w", encoding="utf-8") as needed, \
     (output / "glibc.txt").open("w", encoding="utf-8") as versions:
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) != b"\x7fELF":
                continue
        elf_count += 1
        name = str(path.relative_to(root))
        header = readelf("--file-header", str(path))
        if not re.search(r"Machine:\s+AArch64\b", header):
            errors.append(f"{name}: not AArch64")
        dynamic = readelf("--dynamic", "--wide", str(path))
        libraries = re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic)
        needed.write(f"{name}: {' '.join(libraries) if libraries else '(none)'}\n")
        for lib in libraries:
            if "libLLVM" in lib or "libclang" in lib or "libSPIRV-Tools" in lib:
                errors.append(f"{name}: forbidden compiler runtime dependency {lib}")
        # A private-prefix RPATH would silently bypass SteamOS's libdrm.
        if re.search(r"\((?:RPATH|RUNPATH)\)", dynamic):
            errors.append(f"{name}: unexpected RPATH/RUNPATH (inspect needed build paths)")
        info = readelf("--version-info", "--wide", str(path))
        needs = info.split("Version needs section", 1)[1] if "Version needs section" in info else ""
        tokens = set(re.findall(r"\bGLIBC_([0-9]+(?:\.[0-9]+)+|PRIVATE)\b", needs))
        if "PRIVATE" in tokens:
            errors.append(f"{name}: requires GLIBC_PRIVATE")
        numeric = [tuple(map(int, v.split('.'))) for v in tokens if v != "PRIVATE"]
        local = max(numeric, default=(0, 0))
        highest = max(highest, local)
        versions.write(f"{name}: " + ("GLIBC_" + '.'.join(map(str, local)) if numeric else '(none)') + "\n")
        if local > (2, 39):
            errors.append(f"{name}: requires GLIBC_{'.'.join(map(str, local))}, above GLIBC_2.39")
    label = "GLIBC_" + '.'.join(map(str, highest))
    versions.write(f"HIGHEST: {label}\n")
print(f"Audited {elf_count} installed ELF files; highest requirement: {label}")
if not elf_count:
    errors.append("No ELF files installed")
if errors:
    sys.exit("ERROR: Runtime audit failed:\n" + "\n".join(errors))
PY

phase "Create reproducible root archive"
tar --sort=name --format=gnu --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner \
    -C "$root" -cf - . \
    | zstd -T1 -19 -o "$output_dir/mesa-aurora-steamos-aarch64.tar.zst"
phase "Done: $output_dir/mesa-aurora-steamos-aarch64.tar.zst"
