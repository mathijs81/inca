#!/usr/bin/env bash
# Preflight gate for the agent VM. Portable: meant to run on this laptop AND on
# a cloud dev VM (where it must catch the missing-nested-virt case). Prints
# actionable hints instead of letting later recipes fail cryptically.
set -uo pipefail

PASS=0 WARN=0 FAIL=0
g() { printf '\033[32m  ok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
y() { printf '\033[33m warn \033[0m %s\n' "$1"; WARN=$((WARN+1)); }
r() { printf '\033[31m FAIL \033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '       %s\n' "$1"; }

MEM_MAX="${VM_MEM_MAX:-8GiB}"
IMAGE="${VM_IMAGE:-images:ubuntu/26.04/cloud}"

echo "== agent VM doctor =="

# --- incus present & usable -------------------------------------------------
if command -v incus >/dev/null 2>&1; then
  g "incus installed ($(incus version 2>/dev/null | head -1))"
  if incus storage list >/dev/null 2>&1; then
    g "incus reachable for your user"
    POOL="${VM_STORAGE:-default}"
    if incus storage show "$POOL" >/dev/null 2>&1; then
      g "storage pool '$POOL' exists"
    else
      y "storage pool '$POOL' missing — 'just init' (or provision) will create it"
    fi
    if incus profile device get default root pool >/dev/null 2>&1; then
      g "default profile has a root disk"
    else
      y "default profile has no root disk — 'just init' will attach one (else: 'No root device' on launch)"
    fi
    if incus profile device get default eth0 network >/dev/null 2>&1 \
       || incus profile device get default eth0 nictype >/dev/null 2>&1; then
      g "default profile has a network device"
    else
      y "default profile has no NIC — 'just init' will attach one (else the VM boots with no network)"
    fi
  else
    r "incus not initialized for your user"
    note "run: incus admin init --minimal   (and ensure you're in the 'incus-admin' group)"
  fi
else
  r "incus not installed"
  note "Ubuntu 24.04+:  sudo apt install incus"
  note "or the upstream repo: https://github.com/zabbly/incus  then: sudo apt install incus"
  note "after install:  sudo adduser \"\$USER\" incus-admin && newgrp incus-admin && incus admin init --minimal"
fi

# --- KVM / nested virtualization --------------------------------------------
# NB: systemd-detect-virt exits non-zero (1) when it reports "none" — don't treat that as failure.
VIRT="$(systemd-detect-virt 2>/dev/null)" || true
[ -z "$VIRT" ] && VIRT="unknown"
if [ -e /dev/kvm ] && { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }; then
  g "/dev/kvm present and accessible"
else
  r "/dev/kvm missing or not accessible — VMs can't run with hardware accel"
  [ -e /dev/kvm ] && note "exists but no rw perms; add yourself to the 'kvm' group"
fi

if [ "$VIRT" != "none" ] && [ "$VIRT" != "unknown" ]; then
  note "this host is itself virtualized ($VIRT) → an Incus VM here means NESTED virt"
  nested=""
  for f in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
    [ -r "$f" ] && nested="$(cat "$f")"
  done
  case "$nested" in
    Y|1) g "nested virtualization enabled on this host" ;;
    *)   y "nested virtualization NOT confirmed — '--vm' may be unusable here"
         note "options: (a) use a nested-virt-capable / metal instance,"
         note "         (b) fall back to an Incus system container (launch without --vm) — weaker boundary." ;;
  esac
else
  g "running on bare metal (no nesting concern)"
fi

# --- host RAM vs requested ceiling ------------------------------------------
to_gib() { # crude GiB parser: accepts '8GiB' / '16G' / '2048MiB'
  local v="${1//[!0-9]/}" u="${1//[0-9]/}"
  case "$u" in *M*|*m*) echo $(( v / 1024 ));; *) echo "$v";; esac
}
WANT_GIB="$(to_gib "$MEM_MAX")"
AVAIL_GIB="$(free -g 2>/dev/null | awk '/^Mem:/{print $7}')"
TOTAL_GIB="$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')"
if [ -n "${TOTAL_GIB:-}" ] && [ "$WANT_GIB" -gt 0 ] 2>/dev/null; then
  if [ "$WANT_GIB" -gt "$TOTAL_GIB" ]; then
    y "VM_MEM_MAX=$MEM_MAX exceeds host total RAM (${TOTAL_GIB}GiB) — fine with balloon+swap, but a real peak will swap hard"
  elif [ "$WANT_GIB" -gt "${AVAIL_GIB:-0}" ]; then
    y "VM_MEM_MAX=$MEM_MAX above currently-available RAM (${AVAIL_GIB}GiB free) — ok at idle (free-page-reporting), watch peaks"
  else
    g "VM_MEM_MAX=$MEM_MAX fits available RAM (${AVAIL_GIB}GiB free / ${TOTAL_GIB}GiB total)"
  fi
fi
if swapon --show 2>/dev/null | grep -q .; then
  g "swap present (headroom for VM growth)"
else
  y "no swap — recommended so the host stays calm when the VM balloons up"
fi

# --- host-side tooling for sync / mount / forward ---------------------------
for t in rsync ssh sshfs; do
  if command -v "$t" >/dev/null 2>&1; then g "$t available"
  else y "$t not found (needed for just $( [ "$t" = sshfs ] && echo mount || echo 'sync/forward' ))"
       note "install: sudo apt install $( [ "$t" = sshfs ] && echo sshfs || echo "$t" )"
  fi
done

# --- base image availability ------------------------------------------------
if command -v incus >/dev/null 2>&1; then
  if incus image info "$IMAGE" >/dev/null 2>&1; then
    g "base image $IMAGE available"
    case "$IMAGE" in
      images:*) [[ "$IMAGE" == */cloud ]] || y "$IMAGE looks like a non-cloud image — it likely lacks cloud-init (use 'ubuntu:<rel>' or 'images:.../cloud')" ;;
    esac
  else
    y "base image $IMAGE not found"
    note "list options:  incus image list ubuntu:  |  incus image list images:ubuntu/"
    note "set VM_IMAGE in config/vm.env (images:ubuntu/24.04/cloud is a safe fallback)"
  fi
fi

# --- ghostty terminfo source (host) -----------------------------------------
if infocmp -x xterm-ghostty >/dev/null 2>&1; then
  g "xterm-ghostty terminfo present on host (will be baked into the VM)"
else
  y "no xterm-ghostty terminfo on host — VM terminfo step will be skipped"
  note "harmless unless you SSH in from Ghostty; install Ghostty on the host to fix"
fi

echo
echo "== $PASS ok, $WARN warn, $FAIL fail =="
[ "$FAIL" -eq 0 ]
