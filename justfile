set dotenv-load := true
set dotenv-filename := "config/vm.env"
set shell := ["bash", "-uc"]

NAME    := env_var_or_default("VM_NAME", "inca-vm")
IMAGE   := env_var_or_default("VM_IMAGE", "images:ubuntu/26.04/cloud")
CPU     := env_var_or_default("VM_CPU", "4")
MEM     := env_var_or_default("VM_MEM_MAX", "8GiB")
ROOTSZ  := env_var_or_default("VM_ROOT_SIZE", "40GiB")
USER    := env_var_or_default("VM_USER", "dev")
STORAGE := env_var_or_default("VM_STORAGE", "default")
NETWORK := env_var_or_default("VM_NETWORK", "incusbr0")
GOLDEN  := env_var_or_default("GOLDEN_IMAGE", "inca-golden")
WORK    := "/home/" + USER + "/work"

# Host-side home for shared project trees: INCA_WORK/<vm>/<project> is shared over
# virtiofs into <vm> at work/<project>. The host copy is the source of truth.
INCA_WORK := env_var_or_default("INCA_WORK", env_var("HOME") + "/inca-work")

# Root under which agent-config.txt paths are resolved for push-config/pull-config.
# Default $HOME (your live dotfiles). Point it at one collected dir if you'd rather
# keep all agent config in a single place: INCA_CONFIG_HOME=/home/you/inca-config
INCA_CONFIG := env_var_or_default("INCA_CONFIG_HOME", env_var("HOME"))

SSH_OPTS := "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Incus (7.0.1) builds the balloon without free-page-reporting, so the host keeps
# backing every page the guest has ever touched, long after the guest freed it. This
# override hands freed blocks back. Read at VM start, so a running VM needs a restart.
BALLOON := '[device "qemu_balloon"]' + "\n" + 'free-page-reporting = "on"'

_default:
    @just --list

# Preflight: incus, KVM/nested virt, RAM, host tooling, base image.
[group('setup')]
doctor:
    @bash scripts/doctor.sh

# Ensure a storage pool exists and the default profile has a root disk.
[group('setup')]
init:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! incus storage show "{{STORAGE}}" >/dev/null 2>&1; then
        echo "creating storage pool '{{STORAGE}}' (dir backend)"
        incus storage create "{{STORAGE}}" dir
    fi
    if ! incus profile device get default root pool >/dev/null 2>&1; then
        echo "attaching root disk to default profile"
        incus profile device add default root disk pool="{{STORAGE}}" path=/
    fi
    if ! incus network show "{{NETWORK}}" >/dev/null 2>&1; then
        echo "creating bridge network '{{NETWORK}}'"
        incus network create "{{NETWORK}}"
    fi
    if ! incus profile device get default eth0 nictype >/dev/null 2>&1 \
       && ! incus profile device get default eth0 network >/dev/null 2>&1; then
        echo "attaching network '{{NETWORK}}' to default profile"
        incus profile device add default eth0 nic network="{{NETWORK}}" name=eth0
    fi
    echo "incus ready (storage '{{STORAGE}}', network '{{NETWORK}}', default profile complete)"

# Launch a builder VM, run cloud-init, install your tools into it.
[group('setup')]
provision: doctor init
    -incus delete "{{NAME}}-builder" --force
    incus launch "{{IMAGE}}" "{{NAME}}-builder" --vm -s "{{STORAGE}}" \
        -d root,size="{{ROOTSZ}}" \
        -c limits.cpu="{{CPU}}" -c limits.memory="{{MEM}}" \
        -c security.secureboot=false \
        -c raw.qemu.conf='{{BALLOON}}' \
        -c cloud-init.user-data="$(cat config/cloud-init.yaml)"
    @echo "waiting for guest agent…"
    @until incus exec "{{NAME}}-builder" -- true 2>/dev/null; do sleep 2; done
    @echo "waiting for cloud-init…"
    incus exec "{{NAME}}-builder" -- cloud-init status --wait
    incus exec "{{NAME}}-builder" -- install -d -o {{USER}} -g {{USER}} -m 0755 /home/{{USER}}/.config /home/{{USER}}/.config/mise
    incus file push config/mise-global.toml "{{NAME}}-builder/home/{{USER}}/.config/mise/config.toml" --uid 1000 --gid 1000 --mode 644
    incus file push scripts/setup-tools.sh "{{NAME}}-builder/home/{{USER}}/setup-tools.sh" --uid 1000 --gid 1000 --mode 755
    incus exec "{{NAME}}-builder" --user 1000 --group 1000 --env HOME=/home/{{USER}} -- bash /home/{{USER}}/setup-tools.sh
    @just _terminfo "{{NAME}}-builder"
    @echo "provisioned. next: just bake"

# Bake the provisioned builder into a reusable golden image.
[group('setup')]
bake:
    incus stop "{{NAME}}-builder" || true
    incus publish "{{NAME}}-builder" --alias "{{GOLDEN}}" --reuse
    @echo "golden image '{{GOLDEN}}' ready."
    @echo "you can drop the builder: incus delete {{NAME}}-builder --force"

# Push the host's Ghostty terminfo into a VM (no-op if host lacks it).
_terminfo target:
    @infocmp -x xterm-ghostty 2>/dev/null | incus exec "{{target}}" -- tic -x - \
        && echo "terminfo: xterm-ghostty installed" \
        || echo "terminfo: skipped (no xterm-ghostty on host)"

# secureboot=false: the Zabbly Incus package's AppArmor profile won't grant the
# distro Secure Boot firmware (/usr/share/OVMF/*.ms.fd), so a secureboot VM fails to
# boot with "Permission denied"; we don't need Secure Boot for dev sandboxes anyway.
# Launch a NEW working instance from the golden image and wire up SSH.
[group('instances')]
up name=NAME:
    @if incus info "{{name}}" >/dev/null 2>&1; then echo "{{name}} already exists — 'just start {{name}}' to resume it, or 'just reset {{name}}' for a clean one"; exit 1; fi
    incus launch "{{GOLDEN}}" "{{name}}" --vm -s "{{STORAGE}}" \
        -d root,size="{{ROOTSZ}}" \
        -c limits.cpu="{{CPU}}" -c limits.memory="{{MEM}}" \
        -c security.secureboot=false \
        -c raw.qemu.conf='{{BALLOON}}'
    @echo "waiting for guest agent…"
    @until incus exec "{{name}}" -- true 2>/dev/null; do sleep 1; done
    @echo "waiting for network…"
    @until just ip "{{name}}" >/dev/null 2>&1; do sleep 1; done
    @just _inject-key "{{name}}"
    @echo "waiting for ssh…"
    @until just ssh "{{name}}" true 2>/dev/null; do sleep 1; done
    @just _restore-creds "{{name}}"
    @just push-config "{{name}}"
    @just reshare "{{name}}"
    @echo "{{name}} is up at $(just ip {{name}})  (user: {{USER}})"

# Destroy and relaunch clean from the golden image.
[group('instances')]
reset name=NAME:
    -incus delete "{{name}}" --force
    @just up "{{name}}"

# Inject the host SSH public key so sshfs / port-forward / ssh work.
_inject-key name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    pub=$(ls ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub 2>/dev/null | head -1 || true)
    if [ -z "$pub" ]; then
        echo "No SSH public key (~/.ssh/id_ed25519.pub). Create one: ssh-keygen -t ed25519" >&2
        exit 1
    fi
    incus exec "{{name}}" -- install -d -o {{USER}} -g {{USER}} -m 0700 /home/{{USER}}/.ssh
    incus file push "$pub" "{{name}}/home/{{USER}}/.ssh/authorized_keys" --uid 1000 --gid 1000 --mode 600

# Print the instance's IPv4.
[group('inspect')]
ip name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    # Skip docker0/veth/bridge addresses (Docker runs inside the VM) and take the real NIC.
    ip=$(incus list "{{name}}" -f csv -c 4 \
        | awk '/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ && !/docker|veth|br-|virbr/ {print $1; exit}')
    [ -z "$ip" ] && { echo "no IPv4 for {{name}} (running?)" >&2; exit 1; }
    echo "$ip"

# Interactive auth for the agents. Run the /login flows, then exit, then `just save-creds`.
[group('instances')]
login name=NAME:
    @echo "Authenticate each agent, then 'exit', then run: just save-creds {{name}}"
    @echo "  claude        -> /login"
    @echo "  copilot       -> /login"
    @echo "  cursor-agent login"
    @just ssh "{{name}}"

# Capture agent credentials from an instance to the host (outside the repo, chmod 700).
[group('instances')]
save-creds name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{name}}")
    creds="${INCA_CREDS:-$HOME/.config/inca-creds}"
    install -d -m 700 "$creds"
    grep -vE '^\s*(#|$)' config/cred-paths.txt | while read -r rel; do
        if rsync -aR -e "ssh {{SSH_OPTS}}" "{{USER}}@$ip:/home/{{USER}}/./$rel" "$creds/" 2>/dev/null; then
            echo "  saved $rel"
        else
            echo "  skip  $rel (not present)"
        fi
    done
    echo "creds -> $creds"

# Replay saved credentials into a fresh instance (no-op if none saved). Called by `up`.
_restore-creds name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    creds="${INCA_CREDS:-$HOME/.config/inca-creds}"
    [ -d "$creds" ] || { echo "no saved creds yet ($creds) — run 'just login' then 'just save-creds'"; exit 0; }
    ip=$(just ip "{{name}}")
    grep -vE '^\s*(#|$)' config/cred-paths.txt | while read -r rel; do
        [ -e "$creds/$rel" ] || continue
        rsync -aR -e "ssh {{SSH_OPTS}}" "$creds/./$rel" "{{USER}}@$ip:/home/{{USER}}/"
    done
    echo "creds restored into {{name}}"

# Push global agent config (CLAUDE.md, commands, cursor cli-config, …) into a VM.
# Sourced live from INCA_CONFIG_HOME (default $HOME). Run anytime to sync a
# long-lived instance; also run by `up`. Additive — never deletes guest files.
# -L resolves symlinks: targets are pushed denormalized so the guest gets real
# files/dirs rather than dangling links into paths that never left the host.
[group('instances')]
push-config name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{name}}")
    root="{{INCA_CONFIG}}"
    grep -vE '^\s*(#|$)' config/agent-config.txt | while read -r rel; do
        [ -e "$root/$rel" ] || { echo "  skip   $rel (not in $root)"; continue; }
        rsync -aRL -e "ssh {{SSH_OPTS}}" "$root/./$rel" "{{USER}}@$ip:/home/{{USER}}/"
        echo "  pushed $rel"
    done
    echo "config -> {{name}}"

# Copy agent config back OUT of a VM into INCA_CONFIG_HOME (default $HOME), for when
# you tweaked config inside the guest and want it home. Additive — no deletes.
[group('instances')]
pull-config name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{name}}")
    root="{{INCA_CONFIG}}"
    install -d "$root"
    grep -vE '^\s*(#|$)' config/agent-config.txt | while read -r rel; do
        rsync -aR --ignore-missing-args -e "ssh {{SSH_OPTS}}" \
            "{{USER}}@$ip:/home/{{USER}}/./$rel" "$root/" && echo "  pulled $rel"
    done
    echo "config <- {{name}}  (into $root)"

# rsync a host project dir INTO the VM (excludes node_modules & build caches).
[group('deprecated')]
sync-in path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    src=$(cd "{{invocation_directory()}}" && realpath "{{path}}"); base=$(basename "$src")
    ip=$(just ip "{{name}}")
    rsync -azP --delete --exclude-from=config/rsync-excludes.txt \
        -e "ssh {{SSH_OPTS}}" "$src/" "{{USER}}@$ip:work/$base/"
    echo "synced $base -> {{name}}:{{WORK}}/$base"

# rsync results back OUT to the host (no --delete; skips rebuilt artifacts).
[group('deprecated')]
sync-out path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    dst=$(cd "{{invocation_directory()}}" && realpath "{{path}}"); base=$(basename "$dst")
    ip=$(just ip "{{name}}")
    rsync -azP --exclude-from=config/rsync-excludes.txt \
        -e "ssh {{SSH_OPTS}}" "{{USER}}@$ip:work/$base/" "$dst/"
    echo "synced {{name}}:{{WORK}}/$base -> $dst"

# GitHub auth stays host-side: the untrusted VM never sees your keys/token — it just
# gets the working tree. Edit/commit/push on the host; the VM works the files live.
# Clone a repo into INCA_WORK/<name>/<project> on the host, then share it into <name>.
[group('code')]
clone url name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(basename "{{url}}" .git)
    dest="{{INCA_WORK}}/{{name}}/$base"
    [ -e "$dest" ] && { echo "$dest already exists — remove it or pick another VM" >&2; exit 1; }
    mkdir -p "$(dirname "$dest")"
    git clone "{{url}}" "$dest"
    just share "$base" "{{name}}"

# rsync copy excludes node_modules & build caches; the source dir is left intact.
# Adopt an existing host dir into INCA_WORK/<name>/<project>, then share it into <name>.
[group('code')]
take path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    src=$(cd "{{invocation_directory()}}" && realpath -e "{{path}}"); base=$(basename "$src")
    dest="{{INCA_WORK}}/{{name}}/$base"
    mkdir -p "$dest"
    rsync -aP --exclude-from=config/rsync-excludes.txt "$src/" "$dest/"
    just share "$base" "{{name}}"

# TRUST TRADE-OFF: virtiofs grants the (untrusted) VM read-write access to the host
# dir, unlike the deprecated sync-in/mount which keep the sandbox intact. Use only
# for repos you'd push anyway. Host uid 1000 == VM dev uid 1000, so ownership maps.
# Share INCA_WORK/<name>/<project> into VM <name> at work/<project> (idempotent).
[group('code')]
share project name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    project="{{project}}"
    src="{{INCA_WORK}}/{{name}}/$project"
    dest="{{WORK}}/$project"
    mkdir -p "$src"
    dev="share-${project//[^A-Za-z0-9]/-}"
    # io.cache=unsafe maps to virtiofsd cache=always, giving the guest a page cache
    # to back mmap. Without it virtiofs has no cache and mmap fails — e.g. JVM/JaCoCo
    # zip mmap. Takes effect on the next VM (re)start.
    if incus config device get "{{name}}" "$dev" source >/dev/null 2>&1; then
        # Best-effort reconcile: a live set fails (and rolls back) while the share is
        # mounted/busy, so an already-running VM needs a restart to pick it up.
        if incus config device set "{{name}}" "$dev" io.cache=unsafe 2>/dev/null; then
            echo "{{project}} already shared into {{name}} (io.cache=unsafe ensured)"
        else
            echo "{{project}} already shared into {{name}} — restart it to apply io.cache=unsafe"
        fi
    else
        incus config device add "{{name}}" "$dev" disk source="$src" path="$dest" io.cache=unsafe
        echo "shared $src -> {{name}}:$dest (virtiofs, rw, io.cache=unsafe)"
    fi
    # Incus only auto-mounts virtiofs shares at VM boot; one hot-plugged into a
    # running VM stays unmounted until restart, so mount it live ourselves. The
    # guest mount tag is "incus_<device>" (see /sys/fs/virtiofs/*/tag).
    if [ "$(incus list "{{name}}" -c s -f csv 2>/dev/null)" = RUNNING ]; then
        if incus exec "{{name}}" -- sh -c 'mkdir -p "$2"; chown dev:dev "$2" "$3"; mountpoint -q "$2" || mount -t virtiofs "$1" "$2"' _ "incus_$dev" "$dest" "{{WORK}}"; then
            echo "mounted live at {{name}}:$dest"
        else
            echo "warning: live-mount failed — 'incus restart {{name}}' will mount it on boot" >&2
        fi
    fi

# Stop sharing a project (removes the virtiofs device; the host copy is untouched).
[group('code')]
unshare project name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    project="{{project}}"
    dev="share-${project//[^A-Za-z0-9]/-}"
    dest="{{WORK}}/$project"
    # Unmount in the guest first (while virtiofsd is alive); removing the device on a
    # running VM otherwise leaves a dangling mount. Then drop the empty mountpoint.
    if [ "$(incus list "{{name}}" -c s -f csv 2>/dev/null)" = RUNNING ]; then
        incus exec "{{name}}" -- sh -c 'mountpoint -q "$1" && umount "$1"; rmdir "$1" 2>/dev/null || true' _ "$dest" || true
    fi
    incus config device remove "{{name}}" "$dev"
    echo "unshared {{project}} from {{name}}"

# Called by `up` so a reset VM (which loses its devices) gets its host projects back.
# Re-attach every project under INCA_WORK/<name>/ as a virtiofs share.
[group('code')]
reshare name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    root="{{INCA_WORK}}/{{name}}"
    [ -d "$root" ] || { echo "no host work dir yet ($root)"; exit 0; }
    shopt -s nullglob
    for d in "$root"/*/; do
        just share "$(basename "$d")" "{{name}}"
    done

# Our shares run io.cache=unsafe (cache=always) for working mmap, which can leave the
# guest seeing stale contents after a host-side edit (see TRADEOFFS.md). This drops the
# guest page cache so the next read/mmap re-fetches from the host.
# Run after editing a shared file on the host when the guest must see it immediately.
[group('code')]
flush name=NAME:
    @incus exec "{{name}}" -- sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
    @echo "flushed guest page cache on {{name}}"

# sshfs-mount a guest project on the host for editing (read-write).
[group('deprecated')]
mount path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(basename "$(cd "{{invocation_directory()}}" && realpath "{{path}}")")
    ip=$(just ip "{{name}}")
    mnt="$HOME/inca/$base"; mkdir -p "$mnt"
    # Clear any stale mount first (e.g. a dead one pointing at a prior instance's IP).
    fusermount -u "$mnt" 2>/dev/null || true
    sshfs "{{USER}}@$ip:work/$base" "$mnt" \
        -o reconnect,follow_symlinks,StrictHostKeyChecking=accept-new,UserKnownHostsFile=/dev/null
    echo "mounted (rw) at $mnt"

# Unmount a previously sshfs-mounted project.
[group('deprecated')]
unmount path:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(basename "$(cd "{{invocation_directory()}}" && realpath "{{path}}")")
    fusermount -u "$HOME/inca/$base" && echo "unmounted $HOME/inca/$base"

# Forward one or more guest ports to localhost (Ctrl-C to stop). e.g. just forward myvm 3000 5173
[group('inspect')]
forward name +ports:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{name}}")
    args=(); for p in {{ports}}; do args+=(-L "$p:localhost:$p"); done
    echo "forwarding {{ports}} from {{name}} -> localhost (Ctrl-C to stop)"
    ssh {{SSH_OPTS}} "${args[@]}" -N "{{USER}}@$ip"

# SSH into the instance as the dev user.
[group('inspect')]
ssh name=NAME *args:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{name}}")
    ssh {{SSH_OPTS}} "{{USER}}@$ip" {{args}}

# Root shell via incus (no SSH needed).
[group('inspect')]
root name=NAME:
    incus exec "{{name}}" -- bash -l

# List all instances.
[group('instances')]
list:
    incus list

# Stop a running instance (keeps all its state on disk).
[group('instances')]
stop name=NAME:
    incus stop "{{name}}"

# Resume a stopped instance with all its state intact.
[group('instances')]
start name=NAME:
    incus start "{{name}}"
    @echo "waiting for guest agent…"
    @until incus exec "{{name}}" -- true 2>/dev/null; do sleep 1; done
    @echo "waiting for network…"
    @until just ip "{{name}}" >/dev/null 2>&1; do sleep 1; done
    @echo "{{name}} resumed at $(just ip {{name}})  (user: {{USER}})"

# A restart applies the new size; the Ubuntu cloud image auto-grows the partition
# and filesystem on boot. Growing only — incus cannot shrink a disk.
# Grow an instance's root disk, e.g. `just resize-disk 60GiB inca-vm`.
[group('instances')]
resize-disk size name=NAME:
    incus config device set "{{name}}" root size="{{size}}" \
        || incus config device override "{{name}}" root size="{{size}}"
    incus restart "{{name}}"
    @until incus exec "{{name}}" -- true 2>/dev/null; do sleep 1; done
    @incus exec "{{name}}" -- df -h /

# Memory changes apply live via the virtio-balloon, but only DOWN, or back UP to the
# size the VM booted with (VM_MEM_MAX). To raise it above that boot ceiling, pass
# restart=1 (QEMU can't hot-add RAM the guest never got at boot).
# Set an instance's memory limit, e.g. `just resize-mem 6GiB` or `just resize-mem 16GiB inca-vm restart=1`.
[group('instances')]
resize-mem size name=NAME restart="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{restart}}" ]; then
        # Incus rejects raising memory above the boot-time size on a running VM, so
        # stop it, set the limit while stopped, then start fresh at the new size.
        echo "stopping {{name}} to apply {{size}}…"
        incus stop "{{name}}"
        incus config set "{{name}}" limits.memory "{{size}}"
        incus start "{{name}}"
        until incus exec "{{name}}" -- true 2>/dev/null; do sleep 1; done
    else
        # Live path via the balloon: works going down, or back up to the boot size.
        incus config set "{{name}}" limits.memory "{{size}}"
        echo "set limits.memory={{size}} on {{name}} (live; pass restart=1 to raise above the boot-time size)"
    fi
    incus exec "{{name}}" -- free -h 2>/dev/null || true

# Delete an instance for good.
[group('instances')]
destroy name=NAME:
    incus delete "{{name}}" --force
