#!/bin/sh
# Remove one complete SteamOS for MacBook Neo install, identified by its EFI
# partsets/all files, and its small APFS stub. Resolve UUIDs again before every
# deletion: disk0sN names change as partitions go. DRY_RUN=1 only checks.
set -e

STUB_VOLUME=${STUB_VOLUME:-SteamOS}
STUB_MAX=8000000000
removed=
mounted_by_us=
efi_mount_dir=
finished=0
stop_reason=

fail() { stop_reason=$*; exit 1; }
key() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null || true; }
uuid_of() {
    partition_uuid=$(key "$1" DiskUUID)
    [ -n "$partition_uuid" ] || partition_uuid=$(key "$1" PartitionUUID)
    printf '%s' "$partition_uuid" | tr '[:upper:]' '[:lower:]'
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$mounted_by_us" ]; then
        if ! sudo diskutil unmount "${efi_mount_dir:-$mounted_by_us}"; then
            echo "STOPPING: could not unmount $mounted_by_us"
            status=1
        fi
    fi
    if [ -n "$efi_mount_dir" ]; then
        if ! rmdir "$efi_mount_dir"; then
            echo "STOPPING: could not remove $efi_mount_dir"
            status=1
        fi
    fi
    if [ "$status" -ne 0 ] || [ "$finished" != 1 ]; then
        echo
        echo "STOPPING: ${stop_reason:-a command failed or the operation was interrupted}"
        if [ -n "$removed" ]; then
            echo "Already removed (successful commands):"
            printf '%s\n' "$removed"
        else
            echo "No successful deletions were recorded."
        fi
        echo "Nothing more was deleted."
        echo "If a diskutil deletion failed or was interrupted, inspect the disk before retrying."
        diskutil list internal physical || true
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'fail "interrupted"' HUP INT TERM

# Only accept physical partition identifiers on disk0, never a whole disk.
check_dev() {
    case "$1" in disk0s*) suffix=${1#disk0s} ;; *) fail "$1 is not a partition on disk0" ;; esac
    case "$suffix" in ''|*[!0-9]*) fail "invalid partition device $1" ;; esac
}

# check_part UUID TYPE ROLE -> sets dev, info, part_size
check_part() {
    info=$(diskutil info -plist "$1" 2>/dev/null) || fail "$3 partition $1 not found"
    dev=$(key "$info" DeviceIdentifier)
    check_dev "$dev"
    [ "$(uuid_of "$info")" = "$1" ] || fail "$3 ($dev) UUID does not match $1"
    [ "$(key "$info" ParentWholeDisk)" = disk0 ] || fail "$3 ($dev) is not on the internal disk"
    [ "$(key "$info" Content)" = "$2" ] || fail "$3 ($dev) is not of type $2"
    part_size=$(key "$info" TotalSize)
    case "$part_size" in ''|*[!0-9]*) fail "$3 ($dev) has no valid size" ;; esac
    [ "$part_size" -gt 0 ] || fail "$3 ($dev) is empty"
}

# Sets mount_point. Leave pre-existing read-only mounts alone; refuse writable
# mounts so discovery never changes a user's existing mount or writes to EFI.
mount_efi() {
    mount_info=$(diskutil info -plist "$1") || fail "could not inspect $1 before mounting"
    mount_point=$(key "$mount_info" MountPoint)
    if [ -n "$mount_point" ]; then
        [ "$(key "$mount_info" ReadOnlyVolume)" = true ] || fail "$1 is already mounted writable; unmount it first"
    else
        mounted_by_us=$1
        if sudo diskutil mount readOnly "$1"; then
            mount_info=$(diskutil info -plist "$1") || fail "could not inspect mounted $1"
            mount_point=$(key "$mount_info" MountPoint)
            [ -n "$mount_point" ] || fail "$1 has no mount point after mounting"
            [ "$(key "$mount_info" ReadOnlyVolume)" = true ] || fail "$1 was not mounted read-only"
        else
            [ "$(key "$mount_info" FilesystemType)" = msdos ] || fail "could not mount $1 read-only"
            efi_mount_dir=$(mktemp -d /private/tmp/rs-efi.XXXXXX) || fail "could not create EFI mount directory"
            echo "Using mount_msdos for $1 due to the macOS 4K-sector FAT limitation."
            sudo /sbin/mount_msdos -o rdonly "/dev/$1" "$efi_mount_dir" || fail "could not mount $1 read-only"
            mount_point=$efi_mount_dir
            mount | awk -v dir="$mount_point" '
                index($0, " on " dir " (") && /[ (,]read-only[,)]/ { found=1 }
                END { exit !found }' || fail "$1 was not mounted read-only"
        fi
    fi
}
unmount_efi() {
    if [ -n "$mounted_by_us" ]; then
        sudo diskutil unmount "${efi_mount_dir:-$mounted_by_us}" || fail "could not unmount $mounted_by_us"
        mounted_by_us=
    fi
    if [ -n "$efi_mount_dir" ]; then
        rmdir "$efi_mount_dir" || fail "could not remove $efi_mount_dir"
        efi_mount_dir=
    fi
}

# Validate and canonicalize before comparing manifests (line order may differ).
normalize_parts() {
    awk '
    NF != 2 { bad=1; next }
    {
        name=$1; uuid=$2
        if (name !~ /^(esp|home|efi-A|rootfs-A|var-A|efi-B|rootfs-B|var-B)$/) bad=1
        if (++names[name] != 1 || ++uuids[uuid] != 1) bad=1
        if (uuid ~ /[^0-9a-f-]/ || split(uuid, a, "-") != 5 ||
            length(a[1]) != 8 || length(a[2]) != 4 || length(a[3]) != 4 ||
            length(a[4]) != 4 || length(a[5]) != 12) bad=1
        entries[name]=uuid; count++
    }
    END {
        if (bad || count != 8) exit 1
        n=split("esp home efi-A rootfs-A var-A efi-B rootfs-B var-B", order, " ")
        for (i=1; i<=n; i++) {
            if (!(order[i] in entries)) exit 1
            print order[i], entries[order[i]]
        }
    }'
}

# Find exactly one eligible stub. On subsequent calls, also require its original
# container UUID, physical-store UUID and size. Never trust saved disk numbers.
check_stub() {
    boot_info=$(diskutil info -plist /) || fail "could not inspect booted macOS"
    boot_ref=$(key "$boot_info" APFSContainerReference)
    [ -n "$boot_ref" ] || fail "could not identify the booted macOS container"
    apfs=$(diskutil apfs list -plist) || fail "could not list APFS containers"
    found=0; c=0
    while ref=$(printf '%s' "$apfs" | plutil -extract "Containers.$c.ContainerReference" raw -o - - 2>/dev/null); do
        size=$(key "$apfs" "Containers.$c.CapacityCeiling")
        v=0; has_system=0
        while name=$(printf '%s' "$apfs" | plutil -extract "Containers.$c.Volumes.$v.Name" raw -o - - 2>/dev/null); do
            roles=$(printf '%s' "$apfs" | plutil -extract "Containers.$c.Volumes.$v.Roles" xml1 -o - - 2>/dev/null || true)
            if [ "$name" = "$STUB_VOLUME" ] && printf '%s' "$roles" | grep -q '<string>System</string>'; then
                has_system=1
            fi
            v=$((v + 1))
        done
        if [ "$has_system" = 1 ] && [ "$ref" != "$boot_ref" ]; then
            case "$size" in ''|*[!0-9]*) fail "invalid capacity for $ref" ;; esac
            if [ "$size" -gt 0 ] && [ "$size" -lt "$STUB_MAX" ]; then
                candidate=$(key "$apfs" "Containers.$c.PhysicalStores.0.DeviceIdentifier")
                extra_store=$(key "$apfs" "Containers.$c.PhysicalStores.1.DeviceIdentifier")
                [ -n "$candidate" ] && [ -z "$extra_store" ] || fail "$ref does not have exactly one physical store"
                candidate_info=$(diskutil info -plist "$candidate") || fail "could not inspect $ref physical store"
                if [ "$(key "$candidate_info" ParentWholeDisk)" = disk0 ]; then
                    found=$((found + 1))
                    stub_ref=$ref
                    stub_store=$candidate
                    stub_size=$size
                    stub_uuid=$(key "$apfs" "Containers.$c.APFSContainerUUID" | tr '[:upper:]' '[:lower:]')
                    stub_store_uuid=$(uuid_of "$candidate_info")
                fi
            fi
        fi
        c=$((c + 1))
    done
    [ "$found" = 1 ] || fail "expected exactly one SteamOS stub container, found $found"
    [ -n "$stub_uuid" ] && [ -n "$stub_store_uuid" ] || fail "stub identity is missing"
    if [ -n "${saved_stub_uuid:-}" ]; then
        [ "$stub_uuid" = "$saved_stub_uuid" ] && [ "$stub_store_uuid" = "$saved_store_uuid" ] &&
            [ "$stub_size" = "$saved_stub_size" ] || fail "SteamOS stub identity or size changed"
    fi
    # Resolve the physical store by its UUID too, immediately before deletion.
    check_part "$stub_store_uuid" Apple_APFS stub
    [ "$dev" = "$stub_store" ] || fail "stub physical-store device changed during verification"
    [ "$part_size" = "$stub_size" ] || fail "stub physical-store size does not match its container"
}

echo "Checking SteamOS partitions on disk0..."
diskutil list internal physical
# EFI mounting needs root even for DRY_RUN. Authenticate once for all operations.
sudo -v || fail "sudo authentication failed"
listing=$(diskutil list -plist disk0) || fail "could not list disk0"
[ "$(key "$listing" AllDisksAndPartitions.0.DeviceIdentifier)" = disk0 ] || fail "could not identify disk0"
parts=; sources=; p=0
while scan_dev=$(printf '%s' "$listing" | plutil -extract "AllDisksAndPartitions.0.Partitions.$p.DeviceIdentifier" raw -o - - 2>/dev/null); do
    scan_info=$(diskutil info -plist "$scan_dev") || fail "could not inspect $scan_dev"
    if [ "$(key "$scan_info" Content)" = EFI ]; then
        check_dev "$scan_dev"
        [ "$(key "$scan_info" ParentWholeDisk)" = disk0 ] || fail "$scan_dev is not on disk0"
        scan_uuid=$(uuid_of "$scan_info")
        [ -n "$scan_uuid" ] || fail "$scan_dev has no partition UUID"
        mount_efi "$scan_dev"
        if [ -e "$mount_point/SteamOS/partsets/all" ]; then
            raw_parts=$(cat "$mount_point/SteamOS/partsets/all") || fail "could not read partsets/all on $scan_dev"
            unmount_efi
            candidate_parts=$(printf '%s\n' "$raw_parts" | normalize_parts) || fail "invalid partsets/all on $scan_dev"
            if [ -n "$parts" ]; then
                [ "$parts" = "$candidate_parts" ] || fail "EFI partitions describe different SteamOS installs"
            else
                parts=$candidate_parts
            fi
            sources="${sources}${scan_uuid}
"
        else
            unmount_efi
        fi
    fi
    p=$((p + 1))
done
[ -n "$parts" ] || fail "no complete SteamOS partsets/all found on disk0"

# A manifest must come from one of the two slot EFIs it identifies.
while IFS= read -r source_uuid; do
    [ -n "$source_uuid" ] || continue
    printf '%s\n' "$parts" | awk -v u="$source_uuid" '
        ($1 == "efi-A" || $1 == "efi-B") && $2 == u { found=1 }
        END { exit !found }' || fail "partsets/all came from an EFI outside the identified install"
done <<EOF_SOURCES
$sources
EOF_SOURCES

echo
echo "This will delete the current SteamOS install (nothing else):"
while read -r role uuid; do
    case "$role" in esp|efi-A|efi-B) type=EFI ;; *) type='Linux Filesystem' ;; esac
    check_part "$uuid" "$type" "$role"
    echo "  $role: $dev ($type, $part_size bytes, UUID $uuid)"
    if [ "$role" = esp ]; then
        mount_efi "$dev"
        [ -f "$mount_point/m1n1/boot.bin" ] || fail "SteamOS ESP ($dev) has no m1n1/boot.bin"
        unmount_efi
    fi
done <<EOF_PARTS
$parts
EOF_PARTS
check_stub
saved_stub_uuid=$stub_uuid
saved_store_uuid=$stub_store_uuid
saved_stub_size=$stub_size
echo "  stub: $stub_ref on $stub_store (Apple_APFS, $stub_size bytes, system volume \"$STUB_VOLUME\")"
echo "macOS (booted from $boot_ref) and its recovery are not touched."
echo

if [ "${DRY_RUN:-}" = 1 ]; then
    diskutil list internal physical
    echo "DRY_RUN set: checks passed, nothing deleted."
    finished=1
    exit 0
fi

printf 'Type DELETE to remove the SteamOS install: '
IFS= read -r answer </dev/tty || fail "could not read confirmation from /dev/tty"
[ "$answer" = DELETE ] || fail "not confirmed"

# Recheck the stub before starting, as well as immediately before deleting it.
check_stub
while read -r role uuid; do
    case "$role" in esp|efi-A|efi-B) type=EFI ;; *) type='Linux Filesystem' ;; esac
    check_part "$uuid" "$type" "$role"
    echo "Removing $role ($dev)"
    sudo diskutil eraseVolume free free "$dev" || fail "could not remove $role ($dev, UUID $uuid)"
    removed="${removed}  $role (UUID $uuid; device at deletion: $dev)
"
done <<EOF_PARTS
$parts
EOF_PARTS
check_stub
echo "Removing stub container $stub_ref ($stub_store)"
sudo diskutil apfs deleteContainer "$stub_store" || fail "could not remove stub $stub_uuid ($stub_store)"
removed="${removed}  stub (UUID $stub_uuid; physical store UUID $stub_store_uuid)
"

echo
diskutil list internal physical
echo "Done. The SteamOS install is removed."
finished=1
