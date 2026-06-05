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

SSH_OPTS := "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

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
    incus stop "{{NAME}}-builder"
    incus publish "{{NAME}}-builder" --alias "{{GOLDEN}}" --reuse
    @echo "golden image '{{GOLDEN}}' ready."
    @echo "you can drop the builder: incus delete {{NAME}}-builder --force"

# Push the host's Ghostty terminfo into a VM (no-op if host lacks it).
_terminfo target:
    @infocmp -x xterm-ghostty 2>/dev/null | incus exec "{{target}}" -- tic -x - \
        && echo "terminfo: xterm-ghostty installed" \
        || echo "terminfo: skipped (no xterm-ghostty on host)"

# Launch a NEW working instance from the golden image and wire up SSH.
[group('instances')]
up name=NAME:
    @if incus info "{{name}}" >/dev/null 2>&1; then echo "{{name}} already exists — 'just start {{name}}' to resume it, or 'just reset {{name}}' for a clean one"; exit 1; fi
    incus launch "{{GOLDEN}}" "{{name}}" --vm -s "{{STORAGE}}" \
        -d root,size="{{ROOTSZ}}" \
        -c limits.cpu="{{CPU}}" -c limits.memory="{{MEM}}"
    @echo "waiting for guest agent…"
    @until incus exec "{{name}}" -- true 2>/dev/null; do sleep 1; done
    @echo "waiting for network…"
    @until just ip "{{name}}" >/dev/null 2>&1; do sleep 1; done
    incus exec "{{name}}" -- chown -R {{USER}}:{{USER}} /home/{{USER}}/.config
    @just _inject-key "{{name}}"
    @just _restore-creds "{{name}}"
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

# rsync a host project dir INTO the VM (excludes node_modules & build caches).
[group('deprecated')]
sync-in path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    src=$(realpath "{{path}}"); base=$(basename "$src")
    ip=$(just ip "{{name}}")
    rsync -azP --delete --exclude-from=config/rsync-excludes.txt \
        -e "ssh {{SSH_OPTS}}" "$src/" "{{USER}}@$ip:work/$base/"
    echo "synced $base -> {{name}}:{{WORK}}/$base"

# rsync results back OUT to the host (no --delete; skips rebuilt artifacts).
[group('deprecated')]
sync-out path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    dst=$(realpath "{{path}}"); base=$(basename "$dst")
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
    src=$(realpath -e "{{path}}"); base=$(basename "$src")
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
    src="{{INCA_WORK}}/{{name}}/{{project}}"
    mkdir -p "$src"
    dev="share-${project//[^A-Za-z0-9]/-}"
    if incus config device get "{{name}}" "$dev" source >/dev/null 2>&1; then
        echo "{{project}} already shared into {{name}}"; exit 0
    fi
    incus config device add "{{name}}" "$dev" disk source="$src" path="{{WORK}}/{{project}}"
    echo "shared $src -> {{name}}:{{WORK}}/{{project}} (virtiofs, rw)"

# Stop sharing a project (removes the virtiofs device; the host copy is untouched).
[group('code')]
unshare project name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    dev="share-${project//[^A-Za-z0-9]/-}"
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

# sshfs-mount a guest project on the host for editing (read-write).
[group('deprecated')]
mount path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(basename "$(realpath "{{path}}")")
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
    base=$(basename "$(realpath "{{path}}")")
    fusermount -u "$HOME/inca/$base" && echo "unmounted $HOME/inca/$base"

# Forward one or more guest ports to localhost (Ctrl-C to stop). e.g. just forward 3000 5173
[group('inspect')]
forward +ports:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{NAME}}")
    args=(); for p in {{ports}}; do args+=(-L "$p:localhost:$p"); done
    echo "forwarding {{ports}} from {{NAME}} -> localhost (Ctrl-C to stop)"
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

# Delete an instance for good.
[group('instances')]
destroy name=NAME:
    incus delete "{{name}}" --force
