#!/usr/bin/env bash
# The sync: fast-forward the upstream mirrors (sync/upstreams), rebase every board branch onto its
# synced base (sync/boards), cut the dated snapshots and move the heads. Nothing is pushed until
# every step has passed, and then all of it in one atomic push; any failure stops the run with
# nothing pushed.
#
#   SYNC_DATE=YYYYMMDD  snapshot date (default: today, UTC)
#   SYNC_PUSH=1         push the result (default: print what would be pushed)
#
# Run from a clone of micaoss/mica-linux whose origin is that repository, on main.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
DATE="${SYNC_DATE:-$(date -u +%Y%m%d)}"
PUSH="${SYNC_PUSH:-0}"
WORK="$(mktemp -d)"
export GIT_COMMITTER_NAME="Mica Build" GIT_COMMITTER_EMAIL="build@micaoss.invalid"

die() { echo "sync: error: $*" >&2; exit 1; }
log() { echo "sync: $*"; }
rows() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
cleanup() {
    git worktree list --porcelain | sed -n "s|^worktree \($WORK/.*\)|\1|p" | while read -r wt; do
        git worktree remove --force "$wt"
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

[[ "$DATE" =~ ^[0-9]{8}$ ]] || die "SYNC_DATE must be YYYYMMDD, got $DATE"
git fetch -q --prune origin '+refs/heads/*:refs/remotes/origin/*'

refs=()
leases=()
declare -A MIRROR

# 1. The mirrors: fast-forward only, and inside the pinned series where one is named.
while read -r -u 3 mirror url branch series; do
    old=$(git rev-parse -q --verify "refs/remotes/origin/$mirror^{commit}") || die "origin has no branch $mirror"
    git fetch -q --no-tags "$url" "+refs/heads/$branch:refs/sync/upstream/$mirror"
    new=$(git rev-parse "refs/sync/upstream/$mirror^{commit}")
    if [ -n "${series:-}" ]; then
        mk=$(git show "$new:Makefile")
        got="$(sed -n 's/^VERSION = //p' <<<"$mk" | head -1).$(sed -n 's/^PATCHLEVEL = //p' <<<"$mk" | head -1)"
        [ "$got" = "$series" ] || die "$url $branch is at $got, outside the pinned series $series; moving series is a person's decision (sync/upstreams)"
    fi
    if [ "$new" = "$old" ]; then
        log "$mirror unchanged at $old"
    else
        git merge-base --is-ancestor "$old" "$new" ||
            die "$url $branch ($new) does not descend from $mirror ($old): upstream rewrote its history"
        log "$mirror $old -> $new"
        refs+=("$new:refs/heads/$mirror")
        if [ -n "${series:-}" ]; then
            # The release tags of the series that the mirror gained.
            git fetch -q --no-tags "$url" "+refs/tags/v$series.*:refs/tags/v$series.*"
            while read -r tag; do
                if git merge-base --is-ancestor "$tag^{commit}" "$new" && ! git merge-base --is-ancestor "$tag^{commit}" "$old"; then
                    refs+=("refs/tags/$tag:refs/tags/$tag")
                fi
            done < <(git for-each-ref --format='%(refname:strip=2)' "refs/tags/v$series.*")
        fi
    fi
    MIRROR[$mirror]=$new
done 3< <(rows sync/upstreams)

# Vendors the submodules of the tree checked out at $1 into it, as one commit.
flatten() {
    local wt="$1" base lines=() key path name url sha d date
    base=$(git -C "$wt" rev-parse HEAD)
    while read -r -u 4 key path; do
        name=${key#submodule.}; name=${name%.path}
        url=$(git -C "$wt" config -f .gitmodules "submodule.$name.url")
        sha=$(git -C "$wt" ls-tree HEAD "$path" | awk '{print $3}')
        # .gitmodules comes from upstream: accept only an https URL, a relative path and a gitlink.
        [[ "$url" =~ ^https://[A-Za-z0-9.-]+/ ]] || die "submodule $name: unexpected URL $url"
        [[ "$path" != /* && "$path" != *..* && "$path" != -* && "$name" != */* ]] || die "submodule $name: unexpected path $path"
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "submodule $name: $path is not a gitlink"
        d="$WORK/sub/$name"
        [ -d "$d/.git" ] || git init -q "$d"
        git -C "$d" -c protocol.allow=never -c protocol.https.allow=always fetch -q --depth 1 -- "$url" "$sha"
        git -C "$wt" rm -q --cached "$path"
        rm -rf "${wt:?}/$path"; mkdir -p "$wt/$path"
        git -C "$d" archive "$sha" | tar -x -C "$wt/$path"
        git -C "$wt" add -f "$path"
        lines+=("  $path: $url at $sha")
    done 4< <(git -C "$wt" config -f .gitmodules --get-regexp '^submodule\..*\.path$')
    git -C "$wt" rm -q .gitmodules
    date=$(git -C "$wt" log -1 --format=%cI HEAD)
    {
        echo "Vendor the submodules into the tree"
        echo
        echo "The board's patches change files inside the submodules, which a commit in"
        echo "this tree cannot carry. Their contents at the gitlinks of the base:"
        echo
        printf '%s\n' "${lines[@]}"
        echo
        echo "Mica-Flatten: $base"
    } > "$WORK/flatten-msg"
    GIT_AUTHOR_NAME="$GIT_COMMITTER_NAME" GIT_AUTHOR_EMAIL="$GIT_COMMITTER_EMAIL" \
        GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
        git -C "$wt" commit -q --no-verify -F "$WORK/flatten-msg"
}

# Cuts mica/<name>-DATE at $2 and moves mica/<name> there, unless the newest snapshot already is $2.
snapshot() {
    local name="$1" c="$2" latest head
    latest=$(git for-each-ref --sort=-refname --format='%(refname:strip=3)' "refs/remotes/origin/mica/$name-2*" |
        grep -E "^mica/$name-[0-9]{8}$" | head -1 || true)
    if [ -n "$latest" ] && [ "$(git rev-parse "refs/remotes/origin/$latest")" = "$c" ]; then
        log "mica/$name: no change since $latest"
        return
    fi
    if git rev-parse -q --verify "refs/remotes/origin/mica/$name-$DATE" >/dev/null; then
        die "mica/$name-$DATE already exists at another commit; snapshots are never rewritten (rerun with another SYNC_DATE)"
    fi
    head=$(git rev-parse -q --verify "refs/remotes/origin/mica/$name" || true)
    log "mica/$name-$DATE = $c"
    refs+=("$c:refs/heads/mica/$name-$DATE" "$c:refs/heads/mica/$name")
    # The head moves to the rebased snapshot; the lease refuses if someone pushed to it meanwhile.
    leases+=("--force-with-lease=refs/heads/mica/$name:$head")
}

# 2. general: the stable mirror head, for the boards without commits of their own.
snapshot general "${MIRROR[stable/linux-6.12.y]}"

# 3. The boards: their commits replayed onto the synced base.
while read -r -u 3 board base flat; do
    H=$(git rev-parse -q --verify "refs/remotes/origin/mica/$board^{commit}") || { log "mica/$board does not exist yet; skipped"; continue; }
    B=${MIRROR[$base]:-}
    [ -n "$B" ] || die "sync/boards: $board names $base, which is not a mirror in sync/upstreams"
    if [ "$flat" = yes ]; then
        from=$(git log -1 --format=%H --grep='^Mica-Flatten: ' "$H")
        [ -n "$from" ] || die "mica/$board has no Mica-Flatten commit"
        oldbase=$(git rev-parse "$from^")
    else
        oldbase=$(git merge-base "$H" "$B")
        from=$oldbase
    fi
    git merge-base --is-ancestor "$oldbase" "$B" || die "mica/$board is not based on $base"
    [ -z "$(git rev-list --merges "$from..$H")" ] || die "mica/$board has merge commits after its base; keep it linear"
    if [ "$oldbase" = "$B" ]; then
        result=$H
    else
        wt="$WORK/$board"
        git worktree add -q --detach "$wt" "$B"
        onto=$B
        if [ "$flat" = yes ]; then flatten "$wt"; onto=$(git -C "$wt" rev-parse HEAD); fi
        n=$(git rev-list --count "$from..$H")
        log "mica/$board: rebasing $n commits from $oldbase onto $B"
        git -C "$wt" checkout -q --detach "$H"
        if ! git -C "$wt" rebase -q --onto "$onto" "$from"; then
            git -C "$wt" diff --name-only --diff-filter=U | sed 's/^/  conflict: /' >&2
            git -C "$wt" rebase --abort || true
            die "mica/$board does not rebase cleanly onto $base $B; resolve it by hand on mica/$board"
        fi
        result=$(git -C "$wt" rev-parse HEAD)
        git worktree remove --force "$wt"
    fi
    snapshot "$board" "$result"
done 3< <(rows sync/boards)

if [ "${#refs[@]}" -eq 0 ]; then
    log "nothing to push"
elif [ "$PUSH" = 1 ]; then
    git push --atomic "${leases[@]}" origin "${refs[@]}"
    log "pushed"
else
    log "would push (SYNC_PUSH=1 to push):"
    printf '  %s\n' "${leases[@]}" "${refs[@]}"
fi
