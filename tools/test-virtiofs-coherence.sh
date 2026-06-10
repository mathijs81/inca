#!/usr/bin/env bash
#
# Reproduce / probe the virtiofs host->guest coherence behaviour that bit us:
# the host (the "server", source of truth) edits a shared file and the guest
# (the "client") keeps seeing the old contents.
#
# It exercises the real production setup: a dedicated virtiofs share created via
# `just share`, so it gets io.cache=unsafe (virtiofsd cache=always) exactly like
# the project shares. See TRADEOFFS.md for why we run cache=always.
#
# The script:
#   1. creates a couple of files from the client (guest)
#   2. creates a couple of files from the server (host)
#   3. checks both sides agree on contents (md5sum *)
#   4. does mmap-based reads on the client (proves mmap works under this cache mode)
#   5. modifies an existing file on the server (host), in place, same length
#   6. immediately checks on the client whether the change came through, via:
#        - read() through a fresh open()   (close-to-open path)
#        - mmap() through a fresh map       (what most "open a file" tooling does)
#        - read through a mapping held open ACROSS the host write (the known-weak case)
#
# To compare cache modes, edit the SHARE step (or `just share`) to use a
# different io.cache and rerun; mmap may then fail at step 4.
#
# Usage:  tools/test-virtiofs-coherence.sh [vm-name]
#   CACHE_MODE=unsafe|metadata|none   io.cache for the test share (default: unsafe)
#   KEEP=1                            keep the test share/dir afterwards (default: clean up)
#
# Compare modes:  CACHE_MODE=unsafe   ./tools/test-virtiofs-coherence.sh crypto
#                 CACHE_MODE=metadata ./tools/test-virtiofs-coherence.sh crypto
#                 CACHE_MODE=none     ./tools/test-virtiofs-coherence.sh crypto

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Pull defaults from the same place the justfile does.
# shellcheck disable=SC1091
[ -f config/vm.env ] && set -a && . config/vm.env && set +a || true

VM="${1:-${VM_NAME:-inca-vm}}"
GUSER="${VM_USER:-dev}"
INCA_WORK="${INCA_WORK:-$HOME/inca-work}"
CACHE_MODE="${CACHE_MODE:-unsafe}"   # unsafe (cache=always) | metadata (cache=auto) | none (cache=never)

PROJECT="inca-coherence-test"
HOST_DIR="$INCA_WORK/$VM/$PROJECT"
GUEST_WORK="/home/$GUSER/work"
GUEST_DIR="$GUEST_WORK/$PROJECT"
DEV="share-${PROJECT//[^A-Za-z0-9]/-}"

# ---- pretty output -----------------------------------------------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
else B=; G=; R=; Y=; D=; N=; fi
PASS=0; FAIL=0
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
bad()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
note() { printf '  %s%s%s\n' "$D" "$*" "$N"; }

# ---- guest helper ------------------------------------------------------------
gexec() { incus exec "$VM" --user 1000 --group 1000 --env "HOME=/home/$GUSER" -- "$@"; }
gsh()   { gexec bash -c "$1"; }

if ! incus exec "$VM" -- true 2>/dev/null; then
    echo "VM '$VM' is not reachable (running? guest agent up?)." >&2
    exit 1
fi

# ---- cleanup -----------------------------------------------------------------
cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then
        note "KEEP=1 set — leaving $HOST_DIR and the '$DEV' share in place."
        return
    fi
    incus exec "$VM" -- sh -c "umount '$GUEST_DIR' 2>/dev/null; rmdir '$GUEST_DIR' 2>/dev/null" || true
    incus config device remove "$VM" "$DEV" >/dev/null 2>&1 || true
    rm -rf "$HOST_DIR"
}
trap cleanup EXIT

# =============================================================================
step "Setup: dedicated virtiofs share (io.cache=$CACHE_MODE)"
rm -rf "$HOST_DIR"
mkdir -p "$HOST_DIR"
# Add the share directly (not via `just share`) so we control io.cache and can
# compare modes. A freshly hot-plugged device honours io.cache immediately; the
# "needs a restart" caveat only applies to changing an *existing* mounted share.
incus config device remove "$VM" "$DEV" >/dev/null 2>&1 || true
incus config device add "$VM" "$DEV" disk \
    source="$HOST_DIR" path="$GUEST_DIR" io.cache="$CACHE_MODE" >/dev/null
# Incus only auto-mounts virtiofs shares at boot; mount this hot-plugged one now.
incus exec "$VM" -- sh -c \
    'mkdir -p "$2"; chown dev:dev "$2" "$3"; mountpoint -q "$2" || mount -t virtiofs "$1" "$2"' \
    _ "incus_$DEV" "$GUEST_DIR" "$GUEST_WORK"
CACHE="$(incus config device get "$VM" "$DEV" io.cache 2>/dev/null || echo '?')"
note "host:  $HOST_DIR"
note "guest: $GUEST_DIR   (io.cache=$CACHE)"
gsh "mountpoint -q '$GUEST_DIR'" \
    && ok "share is mounted in the guest" \
    || { bad "share is NOT mounted in the guest — aborting"; exit 1; }

# Build a tiny mmap helper in the guest (gcc is guaranteed by build-essential).
# Modes:
#   once <file>           : print the file's bytes read through a fresh MAP_SHARED map
#   hold <file> <seconds> : map once, print BEFORE bytes, sleep, then print the same
#                           mapping again (AFTER), a fresh read() (REOPEN) and a fresh
#                           mmap (REMAP) — to see which paths observe a host edit that
#                           happened during the sleep.
gsh "cat > /tmp/mmcheck.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

static char *map_ro(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); exit(2); }
    struct stat st;
    if (fstat(fd, &st)) { perror("fstat"); exit(2); }
    *len = (size_t)st.st_size;
    size_t mlen = *len ? *len : 1;
    char *p = mmap(NULL, mlen, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(3); }
    close(fd); /* the mapping survives close() */
    return p;
}

static void emit(const char *tag, const char *buf, size_t len) {
    fputs(tag, stdout);
    fwrite(buf, 1, len, stdout);
    fputc('\n', stdout);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: mmcheck once|hold <file> [secs]\n"); return 64; }
    const char *mode = argv[1];
    const char *path = argv[2];
    size_t len;
    char *m = map_ro(path, &len);

    if (strcmp(mode, "once") == 0) {
        emit("", m, len);
        return 0;
    }
    if (strcmp(mode, "hold") == 0) {
        int secs = argc > 3 ? atoi(argv[3]) : 2;
        emit("BEFORE:", m, len);     /* via the held mapping */
        fflush(stdout);
        sleep(secs);                 /* host edits the file during this window */
        emit("AFTER:", m, len);      /* same held mapping — may be stale */

        int fd = open(path, O_RDONLY);
        char rb[4096];
        ssize_t n = (fd >= 0) ? read(fd, rb, sizeof rb) : -1;
        if (fd >= 0) close(fd);
        emit("REOPEN:", rb, n > 0 ? (size_t)n : 0);   /* fresh read() */

        size_t l2;
        char *m2 = map_ro(path, &l2);
        emit("REMAP:", m2, l2);                        /* fresh mmap */
        return 0;
    }
    fprintf(stderr, "unknown mode %s\n", mode);
    return 64;
}
EOF
gsh "gcc -O0 -o /tmp/mmcheck /tmp/mmcheck.c" && ok "compiled mmap helper in guest" \
    || { bad "could not compile mmap helper"; exit 1; }

# =============================================================================
step "1. Create a couple of files from the CLIENT (guest)"
gsh "printf 'CLIENT-A-v1' > '$GUEST_DIR/client-a.txt'; printf 'CLIENT-B-v1' > '$GUEST_DIR/client-b.txt'"
note "wrote client-a.txt, client-b.txt"

step "2. Create a couple of files from the SERVER (host)"
printf 'SERVER1-v1' > "$HOST_DIR/server-1.txt"
printf 'SERVER2-v1' > "$HOST_DIR/server-2.txt"
note "wrote server-1.txt, server-2.txt"

# =============================================================================
step "3. Both sides agree on contents (md5sum *)"
HOST_SUMS="$(cd "$HOST_DIR" && md5sum -- * | sort -k2)"
GUEST_SUMS="$(gsh "cd '$GUEST_DIR' && md5sum -- * | sort -k2")"
if [ "$HOST_SUMS" = "$GUEST_SUMS" ]; then
    ok "host and guest md5sums match"
    note "$(printf '%s' "$GUEST_SUMS" | sed 's/^/      /')"
else
    bad "host and guest disagree"
    printf '    %s--- host ---%s\n%s\n' "$D" "$N" "$HOST_SUMS"
    printf '    %s--- guest --%s\n%s\n' "$D" "$N" "$GUEST_SUMS"
fi

# =============================================================================
step "4. mmap-based reads on the CLIENT"
MMAP_WORKS=1
for f in client-a.txt server-1.txt server-2.txt; do
    got="$(gexec /tmp/mmcheck once "$GUEST_DIR/$f" 2>&1 || true)"
    want="$(cat "$HOST_DIR/$f")"
    if [ "$got" = "$want" ]; then ok "mmap read $f = '$got'"
    else bad "mmap read $f = '$got' (expected '$want')"; MMAP_WORKS=0; fi
done

# =============================================================================
step "5. Modify an existing file on the SERVER (host), in place"
printf 'SERVER1-v2' > "$HOST_DIR/server-1.txt"   # same length as v1
note "host: server-1.txt  SERVER1-v1 -> SERVER1-v2"

# =============================================================================
step "6. Immediately re-check on the CLIENT — did the change come through?"
EXPECT='SERVER1-v2'

CAT_GOT="$(gsh "cat '$GUEST_DIR/server-1.txt'")"
if [ "$CAT_GOT" = "$EXPECT" ]; then ok "read() (fresh open) sees '$CAT_GOT'"
else bad "read() (fresh open) sees '$CAT_GOT' — STALE (expected '$EXPECT')"; fi

MMAP_GOT="$(gexec /tmp/mmcheck once "$GUEST_DIR/server-1.txt" || echo '<mmap-error>')"
if [ "$MMAP_GOT" = "$EXPECT" ]; then ok "mmap (fresh map) sees '$MMAP_GOT'"
else bad "mmap (fresh map) sees '$MMAP_GOT' — STALE (expected '$EXPECT')"; fi

# Held-mapping case: guest maps server-2.txt and holds it open while the host
# rewrites it. Per TRADEOFFS.md this is the residual weakness of cache=always.
step "6b. Edit a file the client holds mapped open (known-weak case)"
HOLD_OUT="$(mktemp)"
gexec /tmp/mmcheck hold "$GUEST_DIR/server-2.txt" 3 > "$HOLD_OUT" 2>&1 &
HOLD_PID=$!
sleep 1
printf 'SERVER2-v2' > "$HOST_DIR/server-2.txt"   # host edit during the hold window
note "host: server-2.txt  SERVER2-v1 -> SERVER2-v2 (while guest holds it mapped)"
wait "$HOLD_PID" || true

get() { sed -n "s/^$1://p" "$HOLD_OUT"; }
AFTER="$(get AFTER)"; REOPEN="$(get REOPEN)"; REMAP="$(get REMAP)"
note "via held mapping (AFTER): '$AFTER'"
[ "$REOPEN" = 'SERVER2-v2' ] && ok "fresh read() after host edit sees new content" \
                             || bad "fresh read() after host edit sees '$REOPEN' — STALE"
[ "$REMAP"  = 'SERVER2-v2' ] && ok "fresh mmap after host edit sees new content" \
                             || bad "fresh mmap after host edit sees '$REMAP' — STALE"
[ "$AFTER"  = 'SERVER2-v2' ] && note "held mapping ALSO updated (stronger coherence than expected)" \
                             || note "held mapping stayed stale — expected for cache=always (reopen to refresh)"
rm -f "$HOLD_OUT"

# Proposed escape hatch: drop the guest page cache so the next read re-fetches from
# the host. `sync && echo 3 > /proc/sys/vm/drop_caches` (root) evicts clean pages.
# Run last — drop_caches is global, so doing it earlier would perturb the cases above.
DROP_RAN=0; DROP_FIXED=0
if [ "$CAT_GOT" != "$EXPECT" ] || { [ "$MMAP_WORKS" = 1 ] && [ "$MMAP_GOT" != "$EXPECT" ]; }; then
    step "6c. Drop the guest page cache, then re-check (sync; drop_caches)"
    incus exec "$VM" -- sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches' \
        && { DROP_RAN=1; note "guest: sync && echo 3 > /proc/sys/vm/drop_caches (as root)"; } \
        || bad "could not run drop_caches in the guest"
    if [ "$DROP_RAN" = 1 ]; then
        CAT2="$(gsh "cat '$GUEST_DIR/server-1.txt'")"
        if [ "$CAT2" = "$EXPECT" ]; then ok "read() after drop_caches sees '$CAT2'"
        else bad "read() after drop_caches still '$CAT2' — STALE"; fi
        MMAP2="$(gexec /tmp/mmcheck once "$GUEST_DIR/server-1.txt" || echo '<mmap-error>')"
        if [ "$MMAP2" = "$EXPECT" ]; then ok "mmap after drop_caches sees '$MMAP2'"
        else bad "mmap after drop_caches sees '$MMAP2' — STALE"; fi
        [ "$CAT2" = "$EXPECT" ] && { [ "$MMAP_WORKS" != 1 ] || [ "$MMAP2" = "$EXPECT" ]; } && DROP_FIXED=1
    fi
fi

# =============================================================================
# Two independent properties matter, and the cache modes trade them off:
#   - mmap support      : does MAP_SHARED work at all (step 4)?
#   - read coherence    : does a fresh guest open() see a host edit (step 6)?
step "Verdict (io.cache=$CACHE)"
READ_COHERENT=$([ "$CAT_GOT" = "$EXPECT" ] && echo 1 || echo 0)

if [ "$MMAP_WORKS" = 1 ]; then ok "mmap (MAP_SHARED) works"
else bad "mmap (MAP_SHARED) FAILS — breaks JVM/JaCoCo/SQLite/etc."; fi
if [ "$READ_COHERENT" = 1 ]; then ok "host edits ARE visible to a fresh guest open()"
else bad "host edits are NOT visible to a fresh guest open() — the stale-file bug"; fi

echo
if [ "$MMAP_WORKS" = 1 ] && [ "$READ_COHERENT" = 1 ]; then
    printf '  %sIDEAL:%s this mode gives both working mmap and host->guest coherence.\n' "$G" "$N"
elif [ "$MMAP_WORKS" = 1 ]; then
    printf '  %sREPRODUCED your bug:%s mmap works but host edits are invisible on a fresh open.\n' "$R" "$N"
    printf '  This is the cache=always trade-off. Compare: CACHE_MODE=metadata / =none.\n'
    if [ "$DROP_RAN" = 1 ]; then
        if [ "$DROP_FIXED" = 1 ]; then
            printf '  %sWorkaround CONFIRMED:%s `sync && echo 3 > /proc/sys/vm/drop_caches` in the\n' "$G" "$N"
            printf '  guest forces the host edit to become visible — so you can keep cache=always\n'
            printf '  and drop caches after a host-side edit you need the guest to see.\n'
        else
            printf '  %sWorkaround did NOT help:%s drop_caches did not surface the host edit.\n' "$R" "$N"
        fi
    fi
elif [ "$READ_COHERENT" = 1 ]; then
    printf '  %sOther horn of the trade-off:%s coherent host edits, but mmap is broken (ENODEV)\n' "$Y" "$N"
    printf '  — the original problem that forced cache=always. Compare: CACHE_MODE=unsafe.\n'
else
    printf '  %sWorst case:%s neither mmap nor fresh-open coherence works in this mode.\n' "$R" "$N"
fi
if [ "$MMAP_WORKS" = 1 ] && [ "$REOPEN" = 'SERVER2-v2' ]; then
    note "(a mapping held open across the write still read stale — inherent to cache=always)"
fi
printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
