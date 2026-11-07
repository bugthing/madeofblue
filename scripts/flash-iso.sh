#!/usr/bin/env bash
# Download the newest installer ISO built by the "Build disk images" workflow
# and write it to a USB drive chosen from a menu.
#
# Usage: scripts/flash-iso.sh
# Needs: gh (authenticated), lsblk, dd, sudo.

set -euo pipefail

REPO="${REPO:-bugthing/madeofblue}"
ARTIFACT="${ARTIFACT:-madeofblue-anaconda-iso}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/madeofblue/iso"

die() {
	echo "error: $*" >&2
	exit 1
}

for cmd in gh lsblk dd sudo; do
	command -v "$cmd" >/dev/null || die "'$cmd' is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not logged in; run 'gh auth login'"

# --- Find the newest unexpired ISO artifact --------------------------------
echo "Looking up the latest ISO artifact in $REPO..."
read -r run_id created_at size < <(
	gh api "repos/$REPO/actions/artifacts?name=$ARTIFACT&per_page=20" \
		--jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last
		      | "\(.workflow_run.id) \(.created_at) \(.size_in_bytes)"'
) || true
[[ -n "${run_id:-}" && "$run_id" != "null" ]] ||
	die "no unexpired '$ARTIFACT' artifact found; run the 'Build disk images' workflow"

echo "Found run $run_id, built $created_at ($(numfmt --to=iec "$size"))"
echo "  https://github.com/$REPO/actions/runs/$run_id"

# --- Download (cached per run) ---------------------------------------------
run_dir="$CACHE_DIR/$run_id"
iso=$(find "$run_dir" -name '*.iso' -print -quit 2>/dev/null || true)
if [[ -n "$iso" ]]; then
	echo "Using cached ISO: $iso"
else
	rm -rf "$run_dir"
	mkdir -p "$run_dir"
	echo "Downloading to $run_dir (this is several GB)..."
	gh run download "$run_id" --repo "$REPO" --name "$ARTIFACT" --dir "$run_dir"
	iso=$(find "$run_dir" -name '*.iso' -print -quit)
	[[ -n "$iso" ]] || die "artifact contained no .iso file"
	# Drop ISOs from older runs.
	find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "$run_id" -exec rm -rf {} +
fi
iso_size=$(stat -c %s "$iso")

# --- Choose a USB drive ----------------------------------------------------
devices=()
labels=()
while IFS= read -r line; do
	eval "$line" # sets NAME TRAN RM SIZE MODEL TYPE from lsblk -P output
	[[ "$TYPE" == disk ]] || continue
	[[ "$TRAN" == usb || "$RM" == 1 ]] || continue
	devices+=("$NAME")
	labels+=("$NAME  $SIZE  ${MODEL:-unknown} (${TRAN:-removable})")
done < <(lsblk -dnpP -o NAME,TRAN,RM,SIZE,MODEL,TYPE)

((${#devices[@]})) || die "no USB drives found; plug one in and re-run"

echo
echo "Select the USB drive to write $(basename "$iso") to:"
PS3="Drive number (Ctrl-C to abort): "
select label in "${labels[@]}"; do
	[[ -n "$label" ]] && break
	echo "Invalid choice."
done
device="${devices[REPLY - 1]}"

device_size=$(lsblk -dnbo SIZE "$device")
((device_size >= iso_size)) ||
	die "$device ($(numfmt --to=iec "$device_size")) is smaller than the ISO ($(numfmt --to=iec "$iso_size"))"

# Refuse a drive that holds the running system.
if lsblk -lnpo MOUNTPOINTS "$device" | grep -qxE '/|/boot|/boot/efi|/usr|/var|/home'; then
	die "$device holds a system mount; refusing to overwrite it"
fi

echo
echo "About to ERASE everything on:"
lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$device"
read -rp "Type the device name ($device) to confirm: " answer
[[ "$answer" == "$device" ]] || die "confirmation did not match; nothing written"

# --- Write -----------------------------------------------------------------
while read -r part mnt; do
	[[ -n "$mnt" ]] || continue
	echo "Unmounting $part ($mnt)"
	sudo umount "$part"
done < <(lsblk -lnpo NAME,MOUNTPOINT "$device")

echo "Writing $iso to $device..."
sudo dd if="$iso" of="$device" bs=4M status=progress oflag=direct conv=fsync
sync
echo "Done. $device is ready to boot."
