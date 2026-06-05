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
works. Measured cost is smaller than the mode's name suggests:

- Host→guest coherence still holds for the normal loop. virtiofsd does
  close-to-open revalidation, so a host-side edit is visible the next time the
  guest opens the file — the edit-on-host / build-in-guest workflow is unaffected
  in practice. (A file the guest holds *open or mapped* across a host write can
  read stale data until it reopens; that's the residual weakness vs `cache=none`.)
- "unsafe" refers to durability, not corruption: `cache=always` lets the guest
  defer/relax flushes for speed, so a *host* crash could lose recently-written
  guest data. Acceptable for disposable dev VMs whose source of truth is the host
  copy you also commit from.

`io.cache` only takes effect on VM (re)start, and it can't be changed while the
share is mounted (the device is busy) — so existing VMs need a restart to pick it
up; fresh ones get it from boot.

**Stricter alternative (not used here):** split read paths from mmap paths — keep
the source tree on virtiofs at `cache=none` (instant host coherence, source reads
never mmap) and redirect *build output* to the VM's native disk (ext4/xfs), the
only place mmap actually happens. That gives strict source coherence and working
mmap at once, at the cost of build artifacts no longer living on the host. We
prefer the single `cache=always` share for simplicity, since the coherence gap
above hasn't bitten the host-edit/guest-build loop. (`cache=auto`/`metadata` would
be the ideal middle ground, but virtiofsd's auto mode historically hasn't backed
`MAP_SHARED` reliably.)
