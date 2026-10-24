# mica-linux

The Linux kernel trees Mica OS builds: upstream mirrors, one branch per board, and dated snapshots
that [mica-build](https://github.com/micaoss/mica-build) pins in `locks/upstream.lock`.

## Branches

### Upstream mirrors

Upstream history, unchanged: no rebase, no squash, no commit of ours. Each mirror only ever
fast-forwards to its upstream branch head.

| Branch | Upstream | Branch there | First mirrored at |
| --- | --- | --- | --- |
| `stable/linux-6.12.y` | https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git | `linux-6.12.y` | v6.12.111 `e2acc2211022246c77740d5df08265cc27eedcc5` |
| `rockchip/rk-6.1-rkr5.1` | https://github.com/armbian/linux-rockchip.git | `rk-6.1-rkr5.1` | `372ce582b94a3360a29727c3c49c88bb7509da22` |
| `hardkernel/odroids7d-6.12.y` | https://github.com/hardkernel/linux.git | `odroids7d-6.12.y` | `9ea2aa831a585955dcb0e38a0bc3c63d2c690adc` |

The stable mirror stays inside 6.12.y; the `v6.12.*` release tags it contains are pushed with it.
Moving to another series is a person's decision (`sync/upstreams`).

### Board branches and snapshots

| Head | Snapshots | Content | Boards |
| --- | --- | --- | --- |
| `mica/general` | `mica/general-<date>` | `stable/linux-6.12.y` as is | uefi-x64, mini-x64, uefi-arm64, qemu-armhf |
| `mica/cx3576` | `mica/cx3576-<date>` | `rockchip/rk-6.1-rkr5.1` + the board's commits | cx3576 |
| `mica/s905x5m` | `mica/s905x5m-<date>` | `hardkernel/odroids7d-6.12.y` + one commit vendoring its submodules + the board's commits | s905x5m |
| `mica/ssd202d` | `mica/ssd202d-<date>` | `stable/linux-6.12.y` + the board's commits | ssd202d |

- `mica/<board>-<date>` (`<date>` is `YYYYMMDD`, UTC) is a snapshot: created once, never rewritten
  or deleted. mica-build pins snapshots, the newest per board.
- `mica/<board>` is the head: the newest snapshot, and where the board's own changes are made.
  It moves only to a newer snapshot; because a sync rebases the board's commits, that move is not a
  fast-forward, so pull with `git fetch && git reset --hard origin/mica/<board>` before working on it.
- The board's commits started as mica-build's `boards/<board>/kernel/patches` series (one commit per
  patch, in series order, with an `Origin:` trailer naming the patch) after one commit that adds the
  board's device tree from `boards/<board>/kernel/dts`.
- s905x5m: the Hardkernel tree carries `common_drivers` and `media_modules` as submodules, and the
  board's commits change files inside them. The first Mica commit replaces the gitlinks with the
  submodules' contents at those gitlinks (trailer `Mica-Flatten: <base>`), so the snapshot is one
  self-contained tree and every board change is an ordinary commit.

## Sync

`.github/workflows/sync.yml` runs `tools/sync.sh` every Monday at 05:17 UTC and on demand
(workflow_dispatch). It:

1. fast-forwards every mirror in `sync/upstreams` to its upstream head (a head that does not descend
   from the mirror, or a stable head outside 6.12, stops the run);
2. cuts `mica/general-<date>` at the stable mirror head;
3. rebases each board in `sync/boards` onto its synced base (s905x5m: onto a fresh vendoring commit
   at the new base) and cuts `mica/<board>-<date>`;
4. moves the heads to the new snapshots.

A branch whose content did not change gets no new snapshot. Nothing is pushed until every step has
passed, and then everything goes in one atomic push; a head is only replaced if it still is what the
run started from, so a commit pushed to `mica/<board>` during a run is never lost (the push fails and
the next run picks it up).

Run it locally with `bash tools/sync.sh` in a clone of this repository on `main`; it prints what it
would push. `SYNC_PUSH=1` pushes, `SYNC_DATE=YYYYMMDD` sets the snapshot date.

### When the sync stops

A rebase conflict, a rewritten upstream or a series change stops the run with nothing pushed, and
the workflow opens an issue titled `sync failed` (or comments on the open one) with the log. Nothing
is resolved automatically; a person fixes the cause. For a conflict, rebase the board onto the upstream head the run named:

```bash
git fetch origin
git fetch <upstream URL> <upstream branch>         # FETCH_HEAD = the head the run named
git checkout -B work origin/mica/<board>
git rebase --onto FETCH_HEAD <old base>           # resolve and test
git push --force-with-lease=mica/<board>:origin/mica/<board> origin work:mica/<board>
```

then run the workflow again: it finds the board already on the new base and cuts the snapshot.
For s905x5m, `<old base>` is the vendoring commit, and the vendoring commit has to be made at the
new base first (`flatten` in `tools/sync.sh`), with the board's commits rebased onto it.

### Changing a board's kernel

Commit on `mica/<board>` and push. The next sync cuts a snapshot that carries it; for an urgent
change run the workflow by hand (with another `date` when today's snapshot already exists). mica-build
picks the new snapshot up with its next `locks update`.
