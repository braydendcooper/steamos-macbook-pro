#!/bin/bash
# Build the SteamOS slot images for the 16-inch M1 Pro MacBook Pro (J316s) from Valve's SteamOS 0.4.5
# rootfs (10 GiB btrfs), Steam Frame 0.3.0 var/home, Omarchy's Aurora kernel
# and Mesa, and the Neo vendor firmware hooks. Inputs below are overridable
# environment variables. Runs as root in a privileged aarch64 Debian container
# with the build volume at /src and the checkout containing steamos-build/
# at /work.
# NEO_DEBUG_SHELL=1 adds a root shell on tty9, Ctrl+Alt+F9 (development only).
# NEO_AUDIO=1 installs the MacBook Neo audio stack (not for the M1 Pro yet).
#
# Outputs in $OUT:
#   rootfs.img   btrfs root filesystem (0.4.5, Aurora kernel/Mesa, firmware hook)
#   var.img      ext4 /var (Valve's)
#   home.img     ext4 /home (Valve's; grows on first boot via x-systemd.growfs)
#   efi/         files for the installed slot's efi partition: GRUB + grub.cfg
#                (partsets and SteamOS/neo-grubenv are written by the installer)
#   esp/         files for the shared ESP: steamcl.efi and the slot A bootconf
set -euo pipefail

ROOTFS_SRC=${ROOTFS_SRC:-/src/steamos/rootfs-0.4.5/rootfs.img}
SRC=${SRC:-/src/steamos/steamframe-0.3.0.img}
KERNEL_IMAGE=${KERNEL_IMAGE:-/work/build/aurora/Image}
USERPAGES_BIN=${USERPAGES_BIN:-/work/build/aurora/userpages}
MODULES_ROOT=${MODULES_ROOT:-/src/aurora/modules-staging/lib/modules}
MESA_TAR=${MESA_TAR:-/src/aurora/mesa-out/mesa-aurora-steamos-aarch64.tar.zst}
AUDIO_TAR=${AUDIO_TAR:-/src/aurora/audio-out/aurora-audio-steamos-aarch64.tar.zst}
HOOK_DIR=${HOOK_DIR:-/work/steamos-build/initcpio}
OUT=${OUT:-/src/steamos/neo-image}
NEO_DEBUG_SHELL=${NEO_DEBUG_SHELL:-0}
# Audio is off on the M1 Pro until its speaker protection (asahi-audio +
# speakersafetyd) is ported. NEO_AUDIO=1 installs the MacBook Neo audio stack
# from AUDIO_TAR; the machine driver stays blacklisted either way.
NEO_AUDIO=${NEO_AUDIO:-0}
KNAME=linux-neo
BUILD=/work/steamos-build

# Steam Frame services for its own hardware (charger, fans, FPGA, LEDs, eye
# tracking, headset BLE, U-Boot env, VR camera loopback). Masked via /etc.
FRAME_UNITS=(
    deckard-charger deckard-power-monitor deckard-audio-setup deckard-boot-images
    deckard-fan-control deckard-fpga deckard-fpga-resume deckard-led-control
    deckard-typec-logger iris-driver-rebind setubootenv steamvr-program-ble
    steamvr-set-kernel-thread-priorities steamvr-v4l2loopback
)

# Additional Frame-only gadget and codec units, including targets and templates.
FRAME_UNIT_FILES=(
    usb-gadget.service usb-gadget.target adbd.service adbd-pre.service
    adbd-post.service 'dev-usb\x2dffs-adb.mount' steam-video-codec-setup.service
    usb-ncm-gadget@.service usb-ncm-dnsmasq@.service
)

# Replace the Frame's VR session with our per-device flat session package.
NEO_REPLACES=(deckard-steamvr-session)
# Package directories in packages/ that are always built and installed.
SESSION_PACKAGES=(steamos-neo-session aurora-userpages)
AUDIO_PACKAGES=(
    speakerguardd aurora-audio alsa-ucm-conf-aurora
    bankstown-lv2 triforce-lv2 lsp-plugins-lv2
)

mnt=/mnt/neo-rootfs
cleanup() {
    for d in tmp run dev/pts dev sys proc; do umount "$mnt/$d" 2>/dev/null || true; done
    umount "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

# Check inputs before clearing the output directory or mounting anything.
[[ "$NEO_DEBUG_SHELL" == 0 || "$NEO_DEBUG_SHELL" == 1 ]] || {
    echo "NEO_DEBUG_SHELL must be 0 or 1" >&2; exit 1;
}
[[ "$NEO_AUDIO" == 0 || "$NEO_AUDIO" == 1 ]] || {
    echo "NEO_AUDIO must be 0 or 1" >&2; exit 1;
}
build_packages=("${SESSION_PACKAGES[@]}")
audio_inputs=()
if [[ "$NEO_AUDIO" == 1 ]]; then
    build_packages+=("${AUDIO_PACKAGES[@]}")
    audio_inputs=("$AUDIO_TAR")
fi
for input in "$ROOTFS_SRC" "$SRC" "$KERNEL_IMAGE" "$USERPAGES_BIN" "$MESA_TAR" "${audio_inputs[@]}" \
             "$HOOK_DIR/install/neo-vendorfw" "$HOOK_DIR/hooks/neo-vendorfw" \
             "$BUILD/grub.cfg" "$BUILD/kernelsetup.sh"; do
    [[ -f "$input" && -r "$input" ]] || { echo "Missing or unreadable input: $input" >&2; exit 1; }
done
[[ -d "$MODULES_ROOT" && -r "$MODULES_ROOT" && -x "$MODULES_ROOT" ]] || {
    echo "Missing or unreadable modules directory: $MODULES_ROOT" >&2; exit 1;
}
mapfile -t releases < <(find "$MODULES_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
[[ ${#releases[@]} -eq 1 ]] || {
    echo "Expected exactly one kernel release directory in $MODULES_ROOT; found ${#releases[@]}" >&2; exit 1;
}
KREL=${releases[0]}

# Copy GPT partition $1 of $SRC to file $2.
extract_part() {
    local start end
    start=$(sgdisk -i "$1" "$SRC" | awk '/^First sector/ {print $3}')
    end=$(sgdisk -i "$1" "$SRC" | awk '/^Last sector/ {print $3}')
    dd if="$SRC" of="$2" bs=512 skip="$start" count=$((end - start + 1)) conv=sparse status=none
}

# Resolve paths before allowing the output directory to be cleared.
[[ "$OUT" == /* ]] || { echo "Unsafe OUT: must be an absolute path: $OUT" >&2; exit 1; }
OUT=$(realpath -m -- "$OUT") || { echo "Cannot resolve OUT" >&2; exit 1; }
for protected in / /src /work /root /home /usr /etc /var /tmp; do
    protected=$(realpath -m -- "$protected") || {
        echo "Cannot resolve protected directory" >&2; exit 1;
    }
    [[ "$OUT" != "$protected" ]] || {
        echo "Unsafe OUT: protected directory: $OUT" >&2; exit 1;
    }
done
work_dir=$(realpath -m -- /work) || { echo "Cannot resolve /work" >&2; exit 1; }
rootfs_dir=$(realpath -m -- "$(dirname -- "$ROOTFS_SRC")") || {
    echo "Cannot resolve ROOTFS_SRC directory" >&2; exit 1;
}
for protected in "$work_dir" "$rootfs_dir"; do
    [[ "$protected" != "$OUT" && "$protected" != "$OUT"/* ]] || {
        echo "Unsafe OUT: $OUT contains protected directory $protected" >&2; exit 1;
    }
done
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" ]] || { echo "Unsafe OUT: not a directory: $OUT" >&2; exit 1; }
    if [[ ! -f "$OUT/.neo-image-out" || -L "$OUT/.neo-image-out" ]]; then
        (shopt -s nullglob dotglob; entries=("$OUT"/*); [[ ${#entries[@]} -eq 0 ]]) || {
            echo "Unsafe OUT: nonempty directory without .neo-image-out marker: $OUT" >&2; exit 1;
        }
    fi
fi
mkdir -p "$OUT"
touch "$OUT/.neo-image-out"
rm -rf "$OUT"/*
echo "Kernel: $KREL"

echo "== Copying Valve's rootfs and extracting Frame var/home"
cp --sparse=always "$ROOTFS_SRC" "$OUT/rootfs.img"
extract_part 4 "$OUT/var.img"
extract_part 5 "$OUT/home.img"

echo "== Root filesystem"
mkdir -p "$mnt"
mount -o loop "$OUT/rootfs.img" "$mnt"
btrfs property set -ts "$mnt" ro false

# The Frame kernel and its Qualcomm boot chain. /boot/kernelsetup.sh in
# particular makes steamos-finalize-install take the Frame path instead of the
# generic steamcl + GRUB one. The Neo's own kernelsetup.sh is installed with
# the GRUB image below.
rm -rf "$mnt"/boot/Image* "$mnt"/boot/initrd* "$mnt"/boot/*.dtb \
       "$mnt"/boot/dtb* "$mnt"/boot/dtbs "$mnt"/boot/uboot* \
       "$mnt"/boot/ubootfw* "$mnt"/boot/bootfw* \
       "$mnt"/boot/kernelsetup.sh "$mnt"/boot/ubootrelease.txt \
       "$mnt"/etc/mkinitcpio.d/*.preset
find "$mnt/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -exec rm -rf -- {} +

cp "$KERNEL_IMAGE" "$mnt/boot/vmlinuz-$KNAME"
cp -a "$MODULES_ROOT/$KREL" "$mnt/usr/lib/modules/$KREL"
rm -f "$mnt/usr/lib/modules/$KREL/build" "$mnt/usr/lib/modules/$KREL/source"
echo "$KNAME" > "$mnt/usr/lib/modules/$KREL/pkgbase"
# Save space in the 10 GiB rootfs; SteamOS's kmod loads .ko.zst.
find "$mnt/usr/lib/modules/$KREL" -name '*.ko' -print0 | xargs -0 -r -P "$(nproc)" -n 64 zstd -q --rm -19
echo "modules: $(du -sh "$mnt/usr/lib/modules/$KREL" | cut -f1)"

echo "== Aurora Mesa"
shopt -s nullglob
mesa_files=("$mnt"/usr/lib/holo/pacmandb/local/deckard-mesa-linux-aarch64-*/files)
shopt -u nullglob
[[ ${#mesa_files[@]} -eq 1 ]] || {
    echo "Expected exactly one native Valve Mesa package file list; found ${#mesa_files[@]}" >&2; exit 1;
}
# Remove only package-owned files/symlinks, preserving shared directories.
# usr/share/guestos/fex-mesa is Valve's x86 copy for FEX and is out of scope.
while IFS= read -r path; do
    case "$path" in
        ''|usr/share/guestos/fex-mesa|usr/share/guestos/fex-mesa/*) continue ;;
        /*|..|../*|*/../*|*/..) echo "Invalid Mesa package path: $path" >&2; exit 1 ;;
    esac
    if [[ -f "$mnt/$path" || -L "$mnt/$path" ]]; then
        rm -f -- "$mnt/$path"
    fi
done < <(awk '/^%FILES%$/ {files=1; next} /^%/ {files=0} files && NF {print}' "${mesa_files[0]}")
tar --zstd -xpf "$MESA_TAR" -C "$mnt"
compgen -G "$mnt/usr/share/vulkan/icd.d/*asahi*.json" >/dev/null || {
    echo "Aurora Mesa is missing an Asahi ICD JSON" >&2; exit 1;
}
[[ ! -e "$mnt/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json" && \
   ! -L "$mnt/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json" && \
   -e "$mnt/usr/lib/libvulkan_asahi.so" && -e "$mnt/usr/lib/libEGL_mesa.so.0" ]] || {
    echo "Aurora Mesa verification failed: stale Freedreno ICD or missing Asahi/EGL library" >&2; exit 1;
}

install -Dm0644 "$HOOK_DIR/install/neo-vendorfw" "$mnt/usr/lib/initcpio/install/neo-vendorfw"
install -Dm0644 "$HOOK_DIR/hooks/neo-vendorfw" "$mnt/usr/lib/initcpio/hooks/neo-vendorfw"
mkdir -p "$mnt/usr/lib/firmware/vendor"

cat > "$mnt/etc/mkinitcpio.d/$KNAME.preset" <<EOF
# mkinitcpio preset for the MacBook Neo kernel
ALL_kver="/boot/vmlinuz-$KNAME"
PRESETS=('default')
default_image="/boot/initramfs-$KNAME.img"
EOF
cat > "$mnt/etc/mkinitcpio.conf.d/zz-neo.conf" <<'EOF'
# Firmware must be in /lib/firmware/vendor before udev coldplug.
# Drop the Frame firmware hook and retain all other hooks in their order.
neo_hooks=()
neo_has_base=0
for hook in "${HOOKS[@]}"; do
    [[ "$hook" == deckard_fw ]] && continue
    neo_hooks+=("$hook")
    if [[ "$hook" == base ]]; then
        neo_hooks+=(neo-vendorfw)
        neo_has_base=1
    fi
done
if [[ "$neo_has_base" == 0 ]]; then
    neo_hooks=(neo-vendorfw "${neo_hooks[@]}")
fi
HOOKS=("${neo_hooks[@]}")
unset neo_hooks neo_has_base hook
EOF

mkdir -p "$mnt/etc/modprobe.d"
# Keep the machine driver blacklisted until speaker protection is installed and
# validated on the device; override this file from /etc on the device to test.
# On the M1 Pro this driver also runs the headphone jack, so there is no audio.
cat > "$mnt/etc/modprobe.d/neo-no-speakers.conf" <<'EOF'
# No audio until speaker protection (speakersafetyd on the M1 Pro) is installed
# and validated: without it the speakers can be damaged at high volume. The
# kernel holds the speakers 20 dB down until a protection daemon takes over.
# To test, override this file from /etc on the device. Remove the generating
# block in build-image.sh once validated.
blacklist snd_soc_macaudio
EOF

for u in "${FRAME_UNITS[@]}"; do
    ln -sf /dev/null "$mnt/etc/systemd/system/$u.service"
done
for u in "${FRAME_UNIT_FILES[@]}"; do
    ln -sf /dev/null "$mnt/etc/systemd/system/$u"
done
# No login prompt on the USB-C debug UART (in debug builds a getty would
# also split input with the debug shell).
ln -sf /dev/null "$mnt/etc/systemd/system/serial-getty@ttySAC0.service"
# Valve's updater follows the Steam Frame's OS channel; a Frame image cannot
# boot on the Neo and would be written into the fallback slot. No OS updates
# through atomupd/RAUC until there is a Neo update stream.
for u in atomupd.service rauc.service; do
    ln -sf /dev/null "$mnt/etc/systemd/system/$u"
done
echo "== Still-enabled Frame units (if any)"
find "$mnt/etc/systemd/system" -path '*.wants/*' -type l -printf '%P\n' \
    | grep -Ei 'deckard|steamvr|iris|setuboot' \
    | while IFS= read -r unit; do
        [[ $(readlink "$mnt/etc/systemd/system/${unit##*/}") == /dev/null ]] && continue
        echo "$unit"
    done || true

# The Neo has no Frame syspersist partition; waiting for /persist delays boot.
sed -i -E '/^[[:space:]]*PARTLABEL=syspersist([[:space:]]|$)/d' "$mnt/etc/fstab"
echo "== Neo fstab"
cat "$mnt/etc/fstab"
if grep -Eq '^[[:space:]]*PARTLABEL=syspersist([[:space:]]|$)' "$mnt/etc/fstab"; then
    echo "Frame syspersist entry still present in fstab" >&2; exit 1;
fi

# On the Frame, /usr/bin/steamos-bootconf is a wrapper around splctl (Qualcomm
# A/B slot control). The Neo boots like a Steam Deck (steamcl reads bootconfs
# in /esp/SteamOS/conf), so RAUC and steamos-finalize-install must use Valve's
# real steamos-efi tool instead.
ln -sf ../lib/steamos-efi/steamos-bootconf "$mnt/usr/bin/steamos-bootconf"

mount -t proc proc "$mnt/proc"
mount -t sysfs sys "$mnt/sys"
mount --bind /dev "$mnt/dev"
mount --bind /dev/pts "$mnt/dev/pts"
mount -t tmpfs tmpfs "$mnt/run"

# Build with the image's own tools and pacman.conf; all build inputs, outputs
# and pacman cache live on tmpfs so only installed package files persist.
echo "== Neo session and audio packages"
builder_uid=$(chroot "$mnt" id -u nobody) || {
    echo "Neo session build failed: cannot resolve nobody's uid in image" >&2; exit 1;
}
builder_gid=$(chroot "$mnt" id -g nobody) || {
    echo "Neo session build failed: cannot resolve nobody's gid in image" >&2; exit 1;
}
[[ -n "$builder_uid" && -n "$builder_gid" ]] || {
    echo "Neo session build failed: empty nobody uid or gid in image" >&2; exit 1;
}
mount -t tmpfs tmpfs "$mnt/tmp"
mkdir -p "$mnt/tmp/neo-build/out" "$mnt/tmp/neo-build/cache"
for package_name in "${build_packages[@]}"; do
    cp -a "$BUILD/packages/$package_name" "$mnt/tmp/neo-build/"
done
cp "$USERPAGES_BIN" "$mnt/tmp/neo-build/aurora-userpages/userpages"
if [[ "$NEO_AUDIO" == 1 ]]; then
    # Unpack into tmpfs, then give each PKGBUILD only its own DESTDIR payload.
    audio_extract=$(mktemp -d "$mnt/tmp/neo-audio.XXXXXXXX")
    tar --zstd -xpf "$AUDIO_TAR" -C "$audio_extract"
    for package_name in "${AUDIO_PACKAGES[@]}"; do
        [[ -d "$audio_extract/stage/$package_name/usr" ]] || {
            echo "Audio archive missing stage/$package_name/usr" >&2; exit 1;
        }
        mkdir -p "$mnt/tmp/neo-build/$package_name/stage"
        cp -a "$audio_extract/stage/$package_name/." "$mnt/tmp/neo-build/$package_name/stage/"
    done
    rm -rf -- "$audio_extract"
fi
chown -R "$builder_uid:$builder_gid" "$mnt/tmp/neo-build"
for package_name in "${build_packages[@]}"; do
    chroot --userspec="$builder_uid:$builder_gid" "$mnt" env HOME=/tmp/neo-build \
        PKGDEST=/tmp/neo-build/out bash -c \
        'cd "/tmp/neo-build/$1" && makepkg --nodeps --noconfirm --cleanbuild' \
        bash "$package_name"
done
for package_name in "${NEO_REPLACES[@]}"; do
    if chroot "$mnt" pacman -Q "$package_name" >/dev/null 2>&1; then
        chroot "$mnt" pacman -Rdd --noconfirm --logfile /dev/null "$package_name"
    fi
done
# One transaction resolves aurora-audio's dependencies from these packages
# and the image's existing pipewire-audio and wireplumber packages.
chroot "$mnt" bash -c \
    'pacman -U --noconfirm --logfile /dev/null --cachedir /tmp/neo-build/cache /tmp/neo-build/out/*.pkg.tar.zst'
chroot "$mnt" pacman -Q "${build_packages[@]}"
if [[ "$NEO_AUDIO" == 1 ]]; then
# speakerguardd is not enabled at boot while snd_soc_macaudio is blacklisted
# (neo-no-speakers.conf above): with no card it waited 30 s, failed and
# restarted indefinitely, because its restart limit (5 in 60 s) never trips.
# Its udev rule starts it when the AppleJ700 speaker device appears, which
# also covers on-device validation. Enable it again with the blacklist removal.

# Check the actual SteamOS loader and library closure after the transaction.
chroot "$mnt" bash -s <<'AUDIO_LDD'
set -euo pipefail
export LC_ALL=C
bundles=(/usr/lib/lv2/{bankstown,triforce,lsp-plugins}.lv2)
for bundle in "${bundles[@]}"; do
    [[ -d "$bundle" ]] || { echo "Missing audio LV2 bundle: $bundle" >&2; exit 1; }
done
[[ -x /usr/bin/speakerguardd ]] || { echo "Missing speakerguardd" >&2; exit 1; }
elf_count=0
while IFS= read -r -d '' elf; do
    magic=
    IFS= read -r -N 4 magic < "$elf" || continue
    [[ "$magic" == $'\x7fELF' ]] || continue
    elf_count=$((elf_count + 1))
    echo "== ldd $elf"
    if output=$(ldd "$elf" 2>&1); then
        printf '%s\n' "$output"
    else
        printf '%s\n' "$output" >&2
        echo "Audio ldd failed: $elf" >&2
        exit 1
    fi
    if [[ "$output" == *'not found'* ]]; then
        echo "Unresolved audio library: $elf" >&2
        exit 1
    fi
done < <(find /usr/bin/speakerguardd "${bundles[@]}" -type f -print0)
[[ "$elf_count" -ge 4 ]] || { echo "Expected daemon and LV2 ELF files" >&2; exit 1; }
AUDIO_LDD
fi
# Consume the full output so head cannot cause SIGPIPE under pipefail.
chroot "$mnt" pacman -Qi steamos-neo-session | { head; cat >/dev/null; }
chroot "$mnt" pacman -Qo /usr/lib/steamos/gamescope-session
chroot "$mnt" pacman -Qo /usr/bin/aurora-userpages
[[ -f "$mnt/usr/lib/steamos-neo/run-steam" ]] || {
    echo "Neo session verification failed: missing run-steam launcher" >&2; exit 1;
}
umount "$mnt/tmp"

chroot "$mnt" depmod "$KREL"
if ! find "$mnt/usr/lib/modules/$KREL" -type f -name 'snd-soc-macaudio.ko*' -print -quit | grep -q .; then
    echo "Warning: no snd-soc-macaudio module found for $KREL" >&2
fi
chroot "$mnt" mkinitcpio -k "$KREL" -g "/boot/initramfs-$KNAME.img"

echo "== GRUB for the slot efi partitions"
chroot "$mnt" /usr/lib/grub/grub-mkimage -O arm64-efi -d /usr/lib/grub/arm64-efi \
    -p /EFI/steamos -o /tmp/grubaa64.efi \
    part_gpt fat btrfs probe regexp test echo loadenv linux normal configfile \
    efi_gop all_video gzio zstd sleep search search_fs_uuid
cp "$mnt/tmp/grubaa64.efi" "$OUT/grubaa64.efi"
# The update path (kernelsetup.sh) installs these on the slot's efi partition.
install -D -m 644 "$mnt/tmp/grubaa64.efi" "$mnt/usr/lib/steamos-neo/boot/grubaa64.efi"
grub_cfg="$OUT/grub.cfg"
cp "$BUILD/grub.cfg" "$grub_cfg"
if [[ "$NEO_DEBUG_SHELL" == 1 ]]; then
    sed -i '/^linux /s|$| systemd.debug_shell=/dev/tty9|' "$grub_cfg"
    grep -q '^linux .* systemd.debug_shell=/dev/tty9$' "$grub_cfg" || {
        echo "Failed to enable the debug shell in $grub_cfg" >&2; exit 1;
    }
    echo "== DEBUG BUILD: root shell on the screen's tty9 (Ctrl+Alt+F9)"
elif grep -q '^[^#]*debug_shell' "$grub_cfg"; then
    echo "Release GRUB config contains debug_shell: $grub_cfg" >&2; exit 1;
fi
install -D -m 644 "$grub_cfg" "$mnt/usr/lib/steamos-neo/boot/grub.cfg"
install -D -m 755 "$BUILD/kernelsetup.sh" "$mnt/boot/kernelsetup.sh"

echo "== ESP files (steamcl + slot A bootconf)"
mkdir -p "$OUT/esp/EFI/BOOT" "$OUT/esp/EFI/steamos" "$OUT/esp/SteamOS/conf"
cp "$mnt/usr/lib/steamos-efi/aarch64-efi/steamcl.efi" "$OUT/esp/EFI/steamos/steamcl.efi"
cp "$mnt/usr/share/steamos-efi/steamcl-version" "$OUT/esp/EFI/steamos/steamcl-version"
# steamcl-install names its fallback copy bootx64.efi even on aarch64.
cp "$mnt/usr/lib/steamos-efi/aarch64-efi/steamcl.efi" "$OUT/esp/EFI/BOOT/BOOTAA64.EFI"
mkdir -p "$mnt/tmp/neo-conf"
chroot "$mnt" /usr/lib/steamos-efi/steamos-bootconf --conf-dir /tmp/neo-conf create --image A
cp "$mnt/tmp/neo-conf/A.conf" "$OUT/esp/SteamOS/conf/A.conf"
rm -rf "$mnt/tmp/neo-conf" "$mnt/tmp/grubaa64.efi"

for d in run dev/pts dev sys proc; do umount "$mnt/$d"; done
btrfs property set -ts "$mnt" ro true
echo "rootfs usage: $(df -h --output=used,avail "$mnt" | tail -1)"
umount "$mnt"

echo "== Slot efi partition contents"
# The installer formats the slot efi partitions itself (macOS newfs_msdos), so
# the FAT matches the Neo's 4 KiB-sector SSD like the ESP does; a FAT image
# made here had 512-byte sectors, which neither macOS nor Linux will mount
# there. Only the installed slot gets GRUB: a slot with no image must not, or
# steamcl would offer to boot it (the update path adds GRUB when it fills it).
mkdir -p "$OUT/efi/EFI/steamos"
cp "$OUT/grubaa64.efi" "$OUT/efi/EFI/steamos/grubaa64.efi"
cp "$grub_cfg" "$OUT/efi/EFI/steamos/grub.cfg"

ls -la "$OUT" "$OUT/esp/EFI/steamos" "$OUT/esp/SteamOS/conf"
echo "Done: $KREL"
