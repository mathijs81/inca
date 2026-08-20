# Trade-offs

## virtiofs cache mode (`io.cache`) and mmap

Project trees are shared into the guest over virtiofs. The cache mode is the one
knob with real consequences, and Incus exposes it as `io.cache` on the disk
device: `none` (default → virtiofsd `cache=never`), `metadata` (`cache=auto`), and
`unsafe` (`cache=always`).

**The problem:** under the default `cache=none` the guest keeps no page cache for
the share, so `mmap()` of a shared file fails — ordinary `read()`/`write()` work,
but anything that memory-maps a file (the JVM mapping zip/jar central directories,
JaCoCo, SQLite, etc.) errors out with `ENODEV` even though the file is intact.

**What we ship:** `just share` sets `io.cache=unsafe` (`cache=always`) on every
virtiofs device, which gives the guest a page cache to back mappings, so mmap
works. The cost is real and worth understanding:

- **Host→guest coherence is broken under `cache=always`.** A host-side edit is
  *not* reliably visible to the guest — and not just through a file the guest
  holds open/mapped: even a brand-new `open()`/`read()` on the guest can read the
  stale pre-edit contents. virtiofsd's close-to-open revalidation does *not* save
  the edit-on-host / build-in-guest loop here. This is reproducible with
  [`tools/test-virtiofs-coherence.sh`](tools/test-virtiofs-coherence.sh): under
  `cache=always` mmap works but a host edit stays invisible to the guest on a fresh
  open; under `cache=none`/`auto` the host edit is seen but mmap fails. So with a
  single share there is no mode that gives both working mmap and host coherence —
  see the stricter alternative below if the coherence gap bites you. In practice
  the agent does most edits *inside* the guest, so the gap mainly hurts when you
  edit a file on the host and expect the guest to pick it up immediately.
  **Escape hatch:** running `sync && echo 3 > /proc/sys/vm/drop_caches` (as root)
  inside the guest evicts the stale page cache, so the next `read()`/`mmap()`
  re-fetches the file from the host — verified by the test script. Handy when you
  knowingly edit a shared file on the host and need the guest to see it now.
- "unsafe" refers to durability, not corruption: `cache=always` lets the guest
  defer/relax flushes for speed, so a *host* crash could lose recently-written
  guest data. Acceptable for disposable dev VMs whose source of truth is the host
  copy you also commit from.

`io.cache` only takes effect on VM (re)start, and it can't be changed while the
share is mounted (the device is busy) — so existing VMs need a restart to pick it
up; fresh ones get it from boot.

**Stricter alternative (the real fix):** split read paths from mmap paths — keep
the source tree on virtiofs at `cache=none` (instant host coherence, source reads
never mmap) and redirect *build output* to the VM's native disk (ext4/xfs), the
only place mmap actually happens. That gives strict source coherence and working
mmap at once, at the cost of build artifacts no longer living on the host. This is
the only configuration tested that satisfies both constraints; we currently still
ship the single `cache=always` share for simplicity, but the coherence gap above is
real, so prefer this split if host→guest staleness bites you. (`cache=auto` /
`metadata` is *not* a usable middle ground: it fails `mmap` with `ENODEV` exactly
like `cache=none` — confirmed by `tools/test-virtiofs-coherence.sh` — so it buys
nothing over `cache=none` while giving up nothing useful.)

**DAX (not available here):** virtiofs DAX would be the ideal fix — the guest maps
file contents directly through a host-provided memory window, bypassing the guest
page cache entirely, giving working `mmap(MAP_SHARED)` *and* host coherence without
`cache=always`. But it needs a virtiofsd that exposes a DAX cache window. What runs
is the **Rust** `virtiofsd` that Incus bundles at `/opt/incus/bin/virtiofsd` (1.14
here, not the host's `/usr/libexec/virtiofsd`), which has no DAX support (`--cache` is
only the writeback policy); DAX lived only in the old **C** virtiofsd, deprecated and removed
from modern QEMU. Incus also doesn't expose the QEMU `vhost-user-fs` `cache-size`
knob DAX requires. The guest kernel has `CONFIG_FUSE_DAX=y`, but with no host-side
window there's nothing to map — so `-o dax` is a non-starter on this stack.

## Host RAM the VM never gives back

The host keeps backing every page the guest has ever touched, even after the guest
frees it. A VM with `limits.memory: 16GiB` that once peaked near its ceiling sits at
~13.5GB of host RSS forever, while `free` inside the guest reports 4GB used and 11GB
free.

The cause is that Incus (7.0.1) creates the balloon as a plain `virtio-balloon-pci`
with no `free-page-reporting`. Check it from inside the guest — bit 5
(`VIRTIO_BALLOON_F_PAGE_REPORTING`) of the balloon's feature word:

```sh
cat /sys/bus/virtio/devices/virtio0/features   # bit 5 == 1 means reporting is on
```

`just up` and `just provision` now pass this override, so new VMs get it. An existing
VM needs the key set and a restart, because qemu.conf is generated at instance start:

```sh
incus config set <vm> raw.qemu.conf='[device "qemu_balloon"]
free-page-reporting = "on"'
incus restart <vm>
```

With it on the guest hands freed 2MB blocks back and the host `MADV_DONTNEED`s them,
no intervention needed. Measured on a 2GiB test VM: qemu RSS 833MB idle, 1976MB after
the guest touched 1.2GB, back to 826MB about 10 seconds after the guest freed it.

**Reclaiming now, without a restart:** squeeze the balloon by lowering `limits.memory`
on the running VM and raising it back. Incus drives the balloon on that change, and
inflating it does force a real host-side release.

```sh
incus exec <vm> -- sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'   # or: just flush
incus config set <vm> limits.memory 6GiB
incus config set <vm> limits.memory 16GiB
```

Don't squeeze below what the guest is actually using. `VIRTIO_BALLOON_F_DEFLATE_ON_OOM`
is not negotiated either, so an over-inflated balloon OOM-kills things in the guest
instead of giving the memory back.

**virtiofsd is not the leak.** Its RSS looks enormous (9.4GB after 26 days on a busy
share) because vhost-user maps guest RAM into the daemon, so every guest page it has
DMA'd to counts in its RSS. That is the same physical memory as qemu's, counted twice.
Check `/proc/<pid>/statm`: field 2 is resident, field 3 is shared. On ours the
difference — virtiofsd's own heap — was 47MB. Tuning virtiofsd's caching flags does
nothing for this, and the flags usually suggested for it are wrong on the Rust daemon
anyway (`--cache` takes `auto|always|never|metadata`, there is no `--entry-timeout` or
`--attr-timeout`, and `--inode-file-handles` already defaults to `prefer`, which holds
*fewer* fds than the `never` people reach for).
