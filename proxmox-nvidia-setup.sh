#!/usr/bin/env bash
#
# proxmox-nvidia-setup.sh (interactive)
#
# Installs the correct NVIDIA driver on a Proxmox host and (optionally)
# configures GPU passthrough into one or more privileged LXC containers.
#
# Usage:
#   ./proxmox-nvidia-setup.sh install [--version 580.173.02] [--yes]
#   ./proxmox-nvidia-setup.sh lxc-passthrough [--ctid 105] [--yes]
#   ./proxmox-nvidia-setup.sh verify
#
# Run with no arguments for a fully guided interactive menu.
# Must be run as root on the Proxmox HOST (not inside a container/VM).

set -euo pipefail

LOGFILE="/var/log/proxmox-nvidia-setup.log"
DEFAULT_DRIVER_VERSION="580.173.02"
SOURCES_FILE="/etc/apt/sources.list.d/debian.sources"
ASSUME_YES=false

log() {
    echo -e "$1" | tee -a "$LOGFILE"
}

die() {
    log "ERROR: $1"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root."
}

require_host() {
    if [[ -f /proc/1/environ ]] && grep -qa container= /proc/1/environ 2>/dev/null; then
        die "This looks like it's running inside a container. Run this on the Proxmox HOST."
    fi
}

# ---------------------------------------------------------------------------
# Interactive helpers — "confirm to continue" acts as the OK button
# ---------------------------------------------------------------------------

confirm() {
    # confirm "Message to show" -> returns 0 (continue) or exits
    local msg="$1"
    if $ASSUME_YES; then
        log "[auto-confirmed] $msg"
        return 0
    fi
    echo
    echo "──────────────────────────────────────────────"
    echo " $msg"
    echo "──────────────────────────────────────────────"
    read -rp " Press [Enter] to continue (OK), or type 'n' to cancel: " ans
    if [[ "$ans" == "n" || "$ans" == "N" ]]; then
        log "Cancelled by user."
        exit 130
    fi
}

ask() {
    # ask "Prompt text" "default_value" -> echoes the chosen value
    local prompt="$1" default="$2" ans
    read -rp " $prompt [$default]: " ans
    echo "${ans:-$default}"
}

ask_yesno() {
    # ask_yesno "Question" -> returns 0 for yes, 1 for no
    local prompt="$1" ans
    if $ASSUME_YES; then
        return 0
    fi
    read -rp " $prompt (y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# GPU detection
# ---------------------------------------------------------------------------

detect_gpu() {
    log "Detecting NVIDIA GPU(s)..."
    local gpu_line
    gpu_line=$(lspci -nn | grep -i nvidia | grep -i "VGA\|3D controller" || true)

    if [[ -z "$gpu_line" ]]; then
        die "No NVIDIA GPU detected via lspci. Aborting."
    fi

    log "Found:\n$gpu_line"
    echo "$gpu_line"
}

# ---------------------------------------------------------------------------
# Repo setup (non-free / non-free-firmware)
# ---------------------------------------------------------------------------

enable_nonfree_repos() {
    log "Checking apt sources for non-free components..."

    if [[ ! -f "$SOURCES_FILE" ]]; then
        log "WARNING: $SOURCES_FILE not found. Skipping automatic repo edit — verify manually that 'non-free' is enabled."
        return
    fi

    cp "$SOURCES_FILE" "${SOURCES_FILE}.bak.$(date +%s)"
    log "Backed up $SOURCES_FILE"

    if grep -q "non-free-firmware" "$SOURCES_FILE" && ! grep -q "non-free " "$SOURCES_FILE" && ! grep -qE "non-free$" "$SOURCES_FILE"; then
        sed -i 's/non-free-firmware/non-free non-free-firmware/' "$SOURCES_FILE"
        log "Added 'non-free' component to $SOURCES_FILE"
    elif grep -q "non-free non-free-firmware" "$SOURCES_FILE"; then
        log "non-free already enabled, skipping."
    else
        log "Could not confidently auto-edit $SOURCES_FILE — please verify 'contrib non-free non-free-firmware' is present manually."
    fi

    apt update
}

# ---------------------------------------------------------------------------
# Blacklist nouveau
# ---------------------------------------------------------------------------

blacklist_nouveau() {
    log "Blacklisting nouveau..."
    cat << 'EOF' > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u
    log "nouveau blacklisted. Will fully take effect after reboot."
}

# ---------------------------------------------------------------------------
# Headers
# ---------------------------------------------------------------------------

install_headers() {
    local kernel
    kernel=$(uname -r)
    log "Installing headers for running kernel: $kernel"
    apt update
    apt install -y "proxmox-headers-${kernel}" || die "Failed to install headers for ${kernel}. Check that this kernel version has headers available (apt search proxmox-headers)."
}

# ---------------------------------------------------------------------------
# Purge any broken prior driver attempt
# ---------------------------------------------------------------------------

purge_existing_driver() {
    log "Purging any existing NVIDIA driver packages to avoid conflicts..."
    apt purge -y 'nvidia-driver*' 'nvidia-kernel-dkms*' 'libnvidia*' 'nvidia-utils*' 2>/dev/null || true
    apt autoremove -y || true
}

# ---------------------------------------------------------------------------
# Download + install driver
# ---------------------------------------------------------------------------

install_driver() {
    local version="$1"
    local url="https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
    local installer="/tmp/NVIDIA-Linux-x86_64-${version}.run"

    log "Downloading NVIDIA driver ${version}..."
    if ! wget -q --show-progress -O "$installer" "$url"; then
        die "Download failed. Check the version number exists at https://www.nvidia.com/Download/index.aspx (URL tried: $url)"
    fi
    chmod +x "$installer"

    log "Running installer (silent, DKMS mode)..."
    "$installer" \
        --dkms \
        --silent \
        --no-x-check \
        --no-nouveau-check \
        --disable-nouveau \
        --no-cc-version-check \
        || die "NVIDIA installer failed. Check /var/log/nvidia-installer.log for details."

    log "Driver ${version} installed successfully. A REBOOT IS REQUIRED before it's active."
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

verify() {
    log "---- Verification ----"
    log "\n[lspci driver binding]"
    lspci -k | grep -A 3 -i nvidia | tee -a "$LOGFILE"

    log "\n[nvidia-smi]"
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi | tee -a "$LOGFILE"
    else
        log "nvidia-smi not found — driver install may not have completed, or reboot is still pending."
    fi

    log "\n[device nodes]"
    find /dev/nvidia* -maxdepth 0 2>/dev/null | tee -a "$LOGFILE" || log "No /dev/nvidia* nodes present yet (reboot needed, or driver not loaded)."
}

host_driver_version() {
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# LXC passthrough setup
# ---------------------------------------------------------------------------

list_lxc_containers() {
    log "Available LXC containers on this host:"
    pct list | tee -a "$LOGFILE"
}

# Populates two parallel arrays: MENU_CTIDS and MENU_NAMES, from `pct list`
declare -a MENU_CTIDS=()
declare -a MENU_NAMES=()
declare -a MENU_STATUS=()

build_lxc_menu_data() {
    MENU_CTIDS=()
    MENU_NAMES=()
    MENU_STATUS=()
    # pct list output columns: VMID STATUS LOCK NAME
    while read -r vmid status _ name; do
        [[ "$vmid" == "VMID" ]] && continue
        [[ -z "$vmid" ]] && continue
        MENU_CTIDS+=("$vmid")
        MENU_STATUS+=("$status")
        MENU_NAMES+=("$name")
    done < <(pct list)
}

# Interactive numbered menu -> sets SELECTED_CTIDS array
select_lxc_menu() {
    build_lxc_menu_data

    if [[ ${#MENU_CTIDS[@]} -eq 0 ]]; then
        die "No LXC containers found on this host (pct list is empty)."
    fi

    echo
    echo "=================================================="
    echo " Select LXC container(s) for GPU passthrough"
    echo "=================================================="
    for i in "${!MENU_CTIDS[@]}"; do
        printf "  %2d) CTID %-6s %-10s %s\n" "$((i+1))" "${MENU_CTIDS[$i]}" "${MENU_STATUS[$i]}" "${MENU_NAMES[$i]}"
    done
    echo "   a) All containers listed above"
    echo "=================================================="

    local raw
    read -rp " Enter number(s) separated by commas (e.g. 1,3), or 'a' for all: " raw

    SELECTED_CTIDS=()

    if [[ "$raw" == "a" || "$raw" == "A" ]]; then
        SELECTED_CTIDS=("${MENU_CTIDS[@]}")
    else
        IFS=',' read -ra picks <<< "$raw"
        for p in "${picks[@]}"; do
            p="$(echo "$p" | tr -d '[:space:]')"
            if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#MENU_CTIDS[@]} )); then
                SELECTED_CTIDS+=("${MENU_CTIDS[$((p-1))]}")
            else
                log "Ignoring invalid selection: '$p'"
            fi
        done
    fi

    if [[ ${#SELECTED_CTIDS[@]} -eq 0 ]]; then
        die "No valid containers selected."
    fi

    log "Selected container(s): ${SELECTED_CTIDS[*]}"
}

lxc_passthrough() {
    local ctid="$1"
    local conf="/etc/pve/lxc/${ctid}.conf"

    [[ -f "$conf" ]] || die "LXC config not found: $conf (check the CTID with 'pct list')"

    local privileged
    privileged=$(pct config "$ctid" | grep -i "^unprivileged" || echo "unprivileged: 0")
    if echo "$privileged" | grep -q "1"; then
        log "WARNING: container ${ctid} is UNPRIVILEGED. NVIDIA device passthrough generally requires a PRIVILEGED container."
        if ! ask_yesno "Continue anyway (likely to fail)?"; then
            log "Skipping ${ctid}."
            return
        fi
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
        die "nvidia-smi isn't working on this host yet. Run 'install' and reboot before setting up LXC passthrough."
    fi

    if [[ ! -e /dev/nvidia0 ]]; then
        die "/dev/nvidia0 not found. Driver may not be fully loaded — reboot and re-run 'verify' first."
    fi

    log "Detecting device major numbers..."
    local gpu_major uvm_major
    gpu_major=$(stat -c '%t' /dev/nvidia0 | tr -d ',')
    uvm_major=$(stat -c '%t' /dev/nvidia-uvm 2>/dev/null | tr -d ',' || echo "")

    if [[ -z "$uvm_major" ]]; then
        log "WARNING: /dev/nvidia-uvm not found. The nvidia-uvm kernel module may not be loaded."
        log "Try: modprobe nvidia-uvm  (then re-run this command)"
    fi

    log "GPU device major: $gpu_major"
    [[ -n "$uvm_major" ]] && log "UVM device major: $uvm_major"

    confirm "About to modify ${conf} to add GPU passthrough for container ${ctid}, then restart it. A backup will be made first."

    cp "$conf" "${conf}.bak.$(date +%s)"
    log "Backed up $conf"

    # Remove any previous nvidia passthrough lines we may have added before, to avoid duplicates
    sed -i '/nvidia/d' "$conf"

    {
        echo "lxc.cgroup2.devices.allow: c ${gpu_major}:* rwm"
        [[ -n "$uvm_major" ]] && echo "lxc.cgroup2.devices.allow: c ${uvm_major}:* rwm"
        echo "lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file"
        echo "lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file"
        echo "lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file"
        echo "lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file"
        echo "lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file"
    } >> "$conf"

    log "Passthrough config written to $conf"
    log "Restarting container ${ctid}..."
    pct stop "$ctid" 2>/dev/null || true
    pct start "$ctid"

    sleep 3
    log "Checking GPU visibility inside the container..."
    if pct exec "$ctid" -- ls /dev/nvidia0 >/dev/null 2>&1; then
        log "OK: /dev/nvidia0 is visible inside container ${ctid}."

        local drv_ver
        drv_ver=$(host_driver_version)

        if [[ -n "$drv_ver" ]]; then
            if ask_yesno "Install matching nvidia-utils (driver ${drv_ver}) inside container ${ctid} now?"; then
                install_utils_in_lxc "$ctid" "$drv_ver"
            else
                log "Skipped. You can do this later manually:"
                log "   pct exec ${ctid} -- apt install -y nvidia-utils-${drv_ver%%.*}"
            fi
        fi
    else
        log "WARNING: /dev/nvidia0 not visible inside the container yet. Check 'pct config ${ctid}' and container logs."
    fi
}

install_utils_in_lxc() {
    local ctid="$1" version="$2"
    local major="${version%%.*}"

    log "Enabling non-free repos inside container ${ctid} (in case they aren't already)..."
    pct exec "$ctid" -- bash -c "
        f=/etc/apt/sources.list.d/debian.sources
        if [ -f \"\$f\" ] && grep -q \"non-free-firmware\" \"\$f\" && ! grep -q \"non-free \" \"\$f\"; then
            sed -i \"s/non-free-firmware/non-free non-free-firmware/\" \"\$f\"
        fi
    " || log "Could not auto-patch sources inside container — continuing anyway."

    log "Installing nvidia-utils-${major} inside container ${ctid}..."
    pct exec "$ctid" -- apt update || true
    if pct exec "$ctid" -- apt install -y "nvidia-utils-${major}"; then
        log "OK: nvidia-utils-${major} installed in container ${ctid}."
        log "Verifying:"
        pct exec "$ctid" -- nvidia-smi | tee -a "$LOGFILE" || log "nvidia-smi inside container did not run cleanly — check driver/lib version match."
    else
        log "WARNING: could not install nvidia-utils-${major} automatically (package name may differ)."
        log "   Try manually inside the container: apt search nvidia-utils"
    fi
}

lxc_passthrough_multi() {
    local ctids=("$@")
    for id in "${ctids[@]}"; do
        echo
        log "=== Configuring passthrough for container $id ==="
        lxc_passthrough "$id"
    done
}

# ---------------------------------------------------------------------------
# Guided interactive flow
# ---------------------------------------------------------------------------

interactive_menu() {
    echo "=================================================="
    echo " Proxmox NVIDIA GPU Setup — Interactive Mode"
    echo "=================================================="
    echo " 1) Install / repair NVIDIA driver on this host"
    echo " 2) Verify current driver / GPU status"
    echo " 3) Set up GPU passthrough into one or more LXCs"
    echo " 4) Exit"
    echo "=================================================="
    local choice
    choice=$(ask "Choose an option (1-4)" "1")

    case "$choice" in
        1) interactive_install ;;
        2) verify ;;
        3) interactive_lxc ;;
        4) exit 0 ;;
        *) log "Invalid choice."; interactive_menu ;;
    esac
}

interactive_install() {
    detect_gpu

    confirm "This will: enable non-free apt repos, install matching kernel headers, blacklist nouveau, purge any broken NVIDIA packages, then download and install a fresh driver. A REBOOT will be required afterward."

    local version
    version=$(ask "NVIDIA driver version to install" "$DEFAULT_DRIVER_VERSION")

    enable_nonfree_repos
    install_headers
    blacklist_nouveau
    purge_existing_driver
    install_driver "$version"

    log "\n=========================================="
    log "Install complete."
    echo
    if ask_yesno "Reboot now?"; then
        log "Rebooting..."
        reboot
    else
        log "Remember to reboot manually before running 'verify' or LXC passthrough setup."
        if ask_yesno "Set up LXC GPU passthrough now anyway (only works if a driver was already loaded before this install)?"; then
            interactive_lxc
        fi
    fi
}

interactive_lxc() {
    select_lxc_menu
    confirm "About to configure GPU passthrough for container(s): ${SELECTED_CTIDS[*]}"
    lxc_passthrough_multi "${SELECTED_CTIDS[@]}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat << EOF
Usage:
  $0                                       Guided interactive menu
  $0 install [--version X.Y.Z] [--yes]     Install/repair the NVIDIA driver on this host
  $0 verify                                Show current driver/GPU status
  $0 lxc-passthrough --ctid <ID> [--yes]   Configure GPU passthrough into a privileged LXC
                                            (repeat --ctid for multiple containers)

Flags:
  --yes    Skip all confirmation prompts (non-interactive / automation mode)

Examples:
  $0
  $0 install --version 580.173.02 --yes
  $0 lxc-passthrough --ctid 105 --ctid 110
  $0 verify
EOF
}

main() {
    require_root
    require_host
    touch "$LOGFILE"

    local cmd="${1:-}"
    [[ -n "$cmd" ]] && shift || true

    if [[ -z "$cmd" ]]; then
        interactive_menu
        exit 0
    fi

    case "$cmd" in
        install)
            local version="$DEFAULT_DRIVER_VERSION"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --version) version="$2"; shift 2 ;;
                    --yes) ASSUME_YES=true; shift ;;
                    *) die "Unknown argument: $1" ;;
                esac
            done

            detect_gpu > /dev/null
            confirm "About to install NVIDIA driver ${version} on this host (non-free repos, headers, nouveau blacklist, driver install). Reboot required afterward."
            enable_nonfree_repos
            install_headers
            blacklist_nouveau
            purge_existing_driver
            install_driver "$version"

            log "\n=========================================="
            log "Install complete. REBOOT NOW, then run:"
            log "   $0 verify"
            log "=========================================="
            ;;
        verify)
            verify
            ;;
        lxc-passthrough)
            local ctids=()
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --ctid) ctids+=("$2"); shift 2 ;;
                    --yes) ASSUME_YES=true; shift ;;
                    *) die "Unknown argument: $1" ;;
                esac
            done
            if [[ ${#ctids[@]} -eq 0 ]]; then
                log "No --ctid given, opening container selection menu..."
                select_lxc_menu
                ctids=("${SELECTED_CTIDS[@]}")
            fi
            confirm "About to configure GPU passthrough for container(s): ${ctids[*]}"
            lxc_passthrough_multi "${ctids[@]}"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"