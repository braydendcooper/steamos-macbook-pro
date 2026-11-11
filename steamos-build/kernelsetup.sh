#!/bin/bash
# MacBook Neo boot setup for steamos-finalize-install, run from /boot inside
# steamos-chroot for the updated slot instead of Valve's generic steamcl + GRUB
# path, which would replace the Neo GRUB and its static grub.cfg.
# Installed as /boot/kernelsetup.sh by build-image.sh.
set -euo pipefail

fail() {
    echo "kernelsetup: $*" >&2
    exit 1
}

src=/usr/lib/steamos-neo/boot
partsets=/efi/SteamOS/partsets
for file in "$src/grubaa64.efi" "$src/grub.cfg" "$partsets/self"; do
    [[ -f "$file" ]] || fail "missing $file"
done

# Match the updated slot using its partset contents.
ident=
for slot in A B; do
    if cmp -s "$partsets/$slot" "$partsets/self"; then
        [[ -z "$ident" ]] || fail "both A and B match self"
        ident=$slot
    fi
done
[[ -n "$ident" ]] || fail "neither A nor B matches self"
rootfs_partuuid=$(awk '$1 == "rootfs" {print $2; exit}' "$partsets/self")
[[ -n "$rootfs_partuuid" ]] || fail "missing rootfs partition UUID in self"

install -D -m 644 "$src/grubaa64.efi" /efi/EFI/steamos/grubaa64.efi
install -D -m 644 "$src/grub.cfg" /efi/EFI/steamos/grub.cfg
grubenv=/efi/SteamOS/neo-grubenv
if [[ ! -e "$grubenv" ]]; then
    grub-editenv "$grubenv" create
fi
grub-editenv "$grubenv" set "steamos_rootfs_partuuid=$rootfs_partuuid"

if [[ ! -f "/esp/SteamOS/conf/$ident.conf" ]]; then
    mkdir -p /esp/SteamOS/conf
    steamos-bootconf --conf-dir /esp/SteamOS/conf create --image "$ident"
fi
. /etc/os-release || :
steamos-bootconf --conf-dir /esp/SteamOS/conf config --image "$ident" --set comment "${BUILD_ID:-}"

sync
echo "kernelsetup: installed Neo GRUB for slot $ident (rootfs $rootfs_partuuid)"
