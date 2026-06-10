# Inca

**INC**us **A**gents — run coding agents (Claude Code, Cursor CLI, GitHub Copilot
CLI) in disposable [Incus](https://linuxcontainers.org/incus/) VMs, so you can let
them work in `--dangerously-skip-permissions` / no-confirmation mode without giving
them your laptop. Each instance is a throwaway VM cloned from a baked golden image;
your real machine only ever talks to it over SSH and a shared project directory.

Everything is gated through a [`just`](https://github.com/casey/just) file — no
hidden state, just readable recipes.

## Why

Agents are most useful when they can run commands, edit files, and install
things without asking. That's also exactly when you don't want them on your host.
This gives each agent a real Linux box (own kernel, Docker, sudo) that you can
reset to a clean state in seconds and whose only window onto your host is the
project directories you explicitly share into it.

## How it works

1. A **builder** VM is provisioned from a cloud Ubuntu image via cloud-init,
   then your toolchain (mise + the agents) is installed into it.
2. That builder is **baked** into a reusable golden image — tools included, **no
   credentials**.
3. Each `just up` launches a fresh **instance** from the golden image, injects
   your SSH key, replays saved agent credentials, and re-shares your projects.
4. Your code lives on the **host** at `~/inca-work/<vm>/<project>` and is shared
   into the VM over virtiofs at `work/<project>` — near-native speed, no rsync
   round-trips. You edit and run git on the host; the agent works the same files
   live inside the VM. `just reset` for a clean slate; the host copy survives.

Credentials are captured **once** to `~/.config/inca-creds` (chmod 700,
outside this repo) and replayed into each instance. They're never baked into the
image.

## Requirements

- Linux host with **Incus >= 7.0** and hardware virtualization (`/dev/kvm`). On a
  virtualized host you need nested virt, or you can fall back to system
  containers (weaker isolation). The distro package is usually older than 7.0 and
  ignores `io.cache` on virtiofs shares (breaking `mmap`, e.g. JVM/JaCoCo), so
  install from the upstream LTS repo — see the
  [install guide](https://linuxcontainers.org/incus/docs/main/installing/) and
  [upstream packages](https://github.com/zabbly/incus).
- `rsync` and `ssh` (and `sshfs` only for the deprecated `just mount`).
- An SSH keypair (`~/.ssh/id_ed25519`).

Run `just doctor` — it checks all of the above and prints actionable hints.

## Quick start

```sh
just doctor            # preflight: incus, KVM/nested virt, RAM, tooling, base image
just provision         # build + install tools into a builder VM
just bake              # publish the builder as the golden image
just up inca-vm        # launch a fresh instance from the golden image
just login inca-vm     # one-time: run each agent's /login flow inside the VM
just save-creds inca-vm # capture agent creds to the host (do this once)
```

From then on, spinning up a ready-to-go agent box is just:

```sh
just up another-box  # fresh VM, your creds already inside
```

## Daily use

Your projects live on the host at `~/inca-work/<vm>/<project>` and are shared into
the VM over virtiofs at `work/<project>`. Get a project in one of two ways:

```sh
just clone <git-url> inca-vm          # clone host-side (your creds) into inca-work, then share
just take ~/code/myproject inca-vm    # copy an existing dir into inca-work, then share
```

Then work — editing and git happen on the **host**; the agent sees the same files
live in the VM:

```sh
just ssh inca-vm                      # shell in and turn the agent loose
just forward 3000 5173                # forward guest dev-server ports to localhost
git gui                               # …or just run your tools natively against ~/inca-work/inca-vm/myproject
```

Manage shares directly when you need to:

```sh
just share myproject inca-vm          # (re)attach ~/inca-work/inca-vm/myproject
just unshare myproject inca-vm        # detach (host copy untouched)
just reshare inca-vm                  # re-attach everything under ~/inca-work/inca-vm/ (run by `up`)
just flush inca-vm                    # drop the guest page cache after a host-side edit (see TRADEOFFS.md)
```

> **Coherence note:** shares run `io.cache=unsafe` (cache=always) so `mmap` works,
> but the guest can keep serving stale contents after you edit a shared file *on the
> host*. Run `just flush <vm>` to force the guest to re-read it. See
> [`TRADEOFFS.md`](TRADEOFFS.md) for the full story.

Lifecycle:

```sh
just list             # all instances
just stop inca-vm     # freeze (keeps disk state)
just start inca-vm    # resume
just reset inca-vm    # destroy + relaunch clean from golden (host projects re-shared on boot)
just destroy inca-vm  # delete for good
```

Run `just` with no arguments for the full grouped list. The old rsync/sshfs
recipes (`sync-in`, `sync-out`, `mount`) live in a `deprecated` group — use them
only when you deliberately don't want to share host files into an untrusted VM.

> **Trust note:** a shared dir gives the (untrusted) VM read-write access to that
> host directory. Only share repos you'd push anyway. Everything else on your host
> stays out of reach. Host uid 1000 maps to the VM's `dev` user, so ownership lines
> up without extra config.

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
