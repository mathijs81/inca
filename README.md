# incus-agents

Run coding agents (Claude Code, Cursor CLI, GitHub Copilot CLI) in disposable
[Incus](https://linuxcontainers.org/incus/) VMs, so you can let them work in
`--dangerously-skip-permissions` / no-confirmation mode without giving them your
laptop. Each instance is a throwaway VM cloned from a baked golden image; your
real machine only ever talks to it over SSH/rsync.

Everything is gated through a [`just`](https://github.com/casey/just) file — no
hidden state, just readable recipes.

## Why

Agents are most useful when they can run commands, edit files, and install
things without asking. That's also exactly when you don't want them on your host.
This gives each agent a real Linux box (own kernel, Docker, sudo) that you can
reset to a clean state in seconds and that has no access to anything outside it.

## How it works

1. A **builder** VM is provisioned from a cloud Ubuntu image via cloud-init,
   then your toolchain (mise + the agents) is installed into it.
2. That builder is **baked** into a reusable golden image — tools included, **no
   credentials**.
3. Each `just up` launches a fresh **instance** from the golden image, injects
   your SSH key, and replays saved agent credentials.
4. You push code in (rsync or git clone), SSH in, let the agent rip, and pull
   results back out — or `just reset` for a clean slate.

Credentials are captured **once** to `~/.config/agentvm-creds` (chmod 700,
outside this repo) and replayed into each instance. They're never baked into the
image.

## Requirements

- Linux host with Incus and hardware virtualization (`/dev/kvm`). On a
  virtualized host you need nested virt, or you can fall back to system
  containers (weaker isolation).
- `rsync`, `ssh`, and `sshfs` (for `just mount`).
- An SSH keypair (`~/.ssh/id_ed25519`).

Run `just doctor` — it checks all of the above and prints actionable hints.

## Quick start

```sh
just doctor          # preflight: incus, KVM/nested virt, RAM, tooling, base image
just provision       # build + install tools into a builder VM
just bake            # publish the builder as the golden image
just up mybox        # launch a fresh instance from the golden image
just login mybox     # one-time: run each agent's /login flow inside the VM
just save-creds mybox # capture agent creds to the host (do this once)
```

From then on, spinning up a ready-to-go agent box is just:

```sh
just up another-box  # fresh VM, your creds already inside
```

## Daily use

```sh
just sync-in ~/code/myproject mybox   # rsync a project into the VM (skips node_modules, build caches)
just clone <git-url> mybox            # …or clone straight inside the VM
just ssh mybox                        # shell in and turn the agent loose
just sync-out ~/code/myproject mybox  # pull results back to the host
just mount ~/code/myproject mybox     # browse the guest's copy read-only on the host (sshfs)
just forward 3000 5173                # forward guest dev-server ports to localhost
```

Lifecycle:

```sh
just list             # all instances
just stop mybox       # freeze (keeps disk state)
just start mybox      # resume
just reset mybox      # destroy + relaunch clean from golden
just destroy mybox    # delete for good
```

Run `just` with no arguments for the full grouped list.

## Configuration

Defaults live in [`config/vm.env`](config/vm.env) and are safe to override per
host (VM name, image, CPU/RAM, user, storage pool, network, golden-image alias).
Other knobs:

- [`config/mise-global.toml`](config/mise-global.toml) — toolchain mirrored into
  the VM (node, java, tmux, …). Keep roughly in sync with your host config.
- [`config/cred-paths.txt`](config/cred-paths.txt) — which agent auth files get
  captured and replayed. Add a line when you adopt another agent.
- [`config/rsync-excludes.txt`](config/rsync-excludes.txt) — reconstructable
  artifacts the guest rebuilds locally (not synced).
- [`config/cloud-init.yaml`](config/cloud-init.yaml) — machine-level provisioning
  (packages, swap, Docker, the `dev` user).

## License

MIT
