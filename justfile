set dotenv-load := true
set dotenv-filename := "config/vm.env"
set shell := ["bash", "-uc"]

NAME    := env_var_or_default("VM_NAME", "agentbox")
IMAGE   := env_var_or_default("VM_IMAGE", "images:ubuntu/26.04/cloud")
CPU     := env_var_or_default("VM_CPU", "4")
MEM     := env_var_or_default("VM_MEM_MAX", "8GiB")
USER    := env_var_or_default("VM_USER", "dev")
STORAGE := env_var_or_default("VM_STORAGE", "default")
NETWORK := env_var_or_default("VM_NETWORK", "incusbr0")
GOLDEN  := env_var_or_default("GOLDEN_IMAGE", "agentbox-golden")
WORK    := "/home/" + USER + "/work"

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
        -c limits.cpu="{{CPU}}" -c limits.memory="{{MEM}}"
    @echo "waiting for guest agent…"
    @until incus exec "{{name}}" -- true 2>/dev/null; do sleep 1; done
    incus exec "{{name}}" -- chown -R {{USER}}:{{USER}} /home/{{USER}}/.config
    @just _inject-key "{{name}}"
    @just _restore-creds "{{name}}"
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
    creds="${AGENTVM_CREDS:-$HOME/.config/agentvm-creds}"
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
    creds="${AGENTVM_CREDS:-$HOME/.config/agentvm-creds}"
    [ -d "$creds" ] || { echo "no saved creds yet ($creds) — run 'just login' then 'just save-creds'"; exit 0; }
    ip=$(just ip "{{name}}")
    grep -vE '^\s*(#|$)' config/cred-paths.txt | while read -r rel; do
        [ -e "$creds/$rel" ] || continue
        rsync -aR -e "ssh {{SSH_OPTS}}" "$creds/./$rel" "{{USER}}@$ip:/home/{{USER}}/"
    done
    echo "creds restored into {{name}}"

# rsync a host project dir INTO the VM (excludes node_modules & build caches).
[group('code')]
sync-in path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    src=$(realpath "{{path}}"); base=$(basename "$src")
    ip=$(just ip "{{name}}")
    rsync -azP --delete --exclude-from=config/rsync-excludes.txt \
        -e "ssh {{SSH_OPTS}}" "$src/" "{{USER}}@$ip:work/$base/"
    echo "synced $base -> {{name}}:{{WORK}}/$base"

# rsync results back OUT to the host (no --delete; skips rebuilt artifacts).
[group('code')]
sync-out path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    dst=$(realpath "{{path}}"); base=$(basename "$dst")
    ip=$(just ip "{{name}}")
    rsync -azP --exclude-from=config/rsync-excludes.txt \
        -e "ssh {{SSH_OPTS}}" "{{USER}}@$ip:work/$base/" "$dst/"
    echo "synced {{name}}:{{WORK}}/$base -> $dst"

# Git-clone a repo directly inside the VM (alternative to sync-in).
[group('code')]
clone url name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just ip "{{name}}")
    ssh {{SSH_OPTS}} "{{USER}}@$ip" "cd work && git clone '{{url}}'"

# sshfs-mount a guest project on the host for browsing (read-only by default).
[group('inspect')]
mount path name=NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(basename "$(realpath "{{path}}")")
    ip=$(just ip "{{name}}")
    mnt="$HOME/agentvm/$base"; mkdir -p "$mnt"
    sshfs "{{USER}}@$ip:work/$base" "$mnt" \
        -o ro,reconnect,follow_symlinks,StrictHostKeyChecking=accept-new,UserKnownHostsFile=/dev/null
    echo "mounted (ro) at $mnt"

# Unmount a previously sshfs-mounted project.
[group('inspect')]
unmount path:
    #!/usr/bin/env bash
    set -euo pipefail
    base=$(basename "$(realpath "{{path}}")")
    fusermount -u "$HOME/agentvm/$base" && echo "unmounted $HOME/agentvm/$base"

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
    @echo "{{name}} resumed at $(just ip {{name}})  (user: {{USER}})"

# Delete an instance for good.
[group('instances')]
destroy name=NAME:
    incus delete "{{name}}" --force
