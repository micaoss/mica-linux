# mica-linux

The Linux kernel trees Mica OS builds: upstream mirrors, one branch per board, and dated snapshots
that [mica-build](https://github.com/micaoss/mica-build) pins in `locks/upstream.lock`.

## Branches

### Upstream mirrors

Upstream history, unchanged: no rebase, no squash, no commit of ours. A mirror is only ever
fast-forwarded.

| Branch | Upstream | Follows | First mirrored at |
| --- | --- | --- | --- |
| `stable/linux-6.12.y` | https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git | point releases `v6.12.<n>` (tags pushed with it) | v6.12.111 `e2acc2211022246c77740d5df08265cc27eedcc5` |
| `rockchip/rk-6.1-rkr5.1` | https://github.com/armbian/linux-rockchip.git | branch `rk-6.1-rkr5.1` | `372ce582b94a3360a29727c3c49c88bb7509da22` |
| `hardkernel/odroids7d-6.12.y` | https://github.com/hardkernel/linux.git | branch `odroids7d-6.12.y` | `9ea2aa831a585955dcb0e38a0bc3c63d2c690adc` |

### Board branches and snapshots

| Head | Content | Boards |
| --- | --- | --- |
| `mica/general` | `stable/linux-6.12.y` as is | mini-x64, uefi-x64, uefi-arm64 |
| `mica/qemu-armhf` | `stable/linux-6.12.y` + the board's commits | qemu-armhf |
| `mica/ssd202d` | `stable/linux-6.12.y` + the board's commits | ssd202d |
| `mica/cx3576` | `rockchip/rk-6.1-rkr5.1` + the board's commits | cx3576 |
| `mica/s905x5m` | `hardkernel/odroids7d-6.12.y` + one commit vendoring its submodules + the board's commits | s905x5m |

- `mica/<board>-<YYYYMMDD>` (UTC), or `mica/<board>-<YYYYMMDD>-<HHMM>` for a second cut the same day, is a
  snapshot: only ever created, never rewritten or deleted. A build pins a snapshot, never a head or a mirror.
- `mica/<board>` is the head: it points at the newest snapshot. It is the one ref that moves to a rebased tree, and
  only with a lease on the value it had.
- The board's commits started as mica-build's `boards/<board>/kernel/patches` series, one commit per patch in series
  order with an `Origin:` trailer naming the patch, after one commit adding the board's device tree from
  `boards/<board>/kernel/dts` (cx3576, s905x5m; qemu-armhf boots QEMU's own device tree). Out-of-tree modules stay in
  mica-build.
- s905x5m: the Hardkernel tree carries `common_drivers` and `media_modules` as submodules, and the board's commits
  change files inside them. The first Mica commit replaces the gitlinks with the submodules' contents at those
  gitlinks (trailer `Mica-Flatten: <base>`), so a snapshot is one self-contained tree and every board change is an
  ordinary commit.

## Sync

[sync.yml](.github/workflows/sync.yml) runs [scripts/sync.sh](scripts/sync.sh) every Monday at 03:17 UTC (and on
demand, with a dry run option). For each `mirror` row of [sync.tsv](sync.tsv) it fetches the upstream and
fast-forwards the mirror branch; a `release:<tag>` row follows only the point releases of that release
(`<tag>.<n>`), and a `branch:<name>` row follows that branch's head. Then every board whose `mica/<board>` is not
based on its mirror's head gets its commits (merge base to `mica/<board>`) cherry-picked onto that head, in order;
a `flatten` board first gets a new vendoring commit at that head, in place of its old one. The result is pushed as
`mica/<board>-<date>` (`mica/<board>-<date>-<HHMM>` when that day already has one) and `mica/<board>` moves to it.
A commit the new upstream already carries applies as nothing and is dropped.

The rules: a mirror is only ever fast-forwarded; a snapshot is only ever created; `mica/<board>` is the one ref that
moves to a rebased tree, and only with a lease on the value the run read. mica-build's `locks update` picks the
newest dated branch of the row: the greatest name as a string, so `-<HHMM>` comes after the plain date.

A new kernel series (the next stable line, a new vendor branch) is a human decision: add its `mirror` row, point
the boards' rows at it, and the next run creates the mirror and rebases those boards onto it.

## Conflicts

A row that cannot go through pushes nothing for that row, is written to the run's report and the run fails with an
issue titled `sync <date>: rows need a human`; the other rows still go through. The cases: an upstream that is not a
fast-forward of the mirror (upstream rewrote history), a board commit that does not apply on the new base, a
submodule that cannot be vendored, and a snapshot name that is already taken, the `-<HHMM>` one included. A board
left behind is retried on every run until it is resolved, since its `mica/<board>` stays off its mirror's head.

To resolve a conflict, rebase the board's commits onto the mirror head by hand (for s905x5m: onto a new vendoring
commit at that head, `flatten` in `scripts/sync.sh`), and push the result as a new snapshot and the moving head, as
in "Making a change". For a rewritten upstream, decide whether to follow it; a mirror is never force-pushed, so
following it means a new mirror branch and new board rows.

## Making a change

A change to a board is a commit on its tree, made the same way the sync makes one:

1. Start from `mica/<board>`, add the commit(s), and build and test the board in mica-build against the result.
2. Push it as `mica/<board>-<YYYYMMDD>` (today, UTC), or `mica/<board>-<YYYYMMDD>-<HHMM>` when today already has
   one, and fast-forward `mica/<board>` to it. An existing snapshot name is never reused.
3. Pin the snapshot in mica-build (`locks update`).

The commit subject and body say what the change does and why, as in the kernel's own history. A change meant for
every board belongs upstream first; a board that only needs the plain stable kernel uses `mica/general-<date>`.
