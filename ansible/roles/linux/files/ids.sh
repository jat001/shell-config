set -eu

# Usage: ids.sh check|apply USER UID GID [NAME=ID ...]
# Gives USER the uid and gid, and each NAME group (and a same-named user, if any) the ID.
# IDs held by accounts outside this set stop the run; files that carried an old ID get the new one.
mode=$1
user=$2
uid=$3
gid=$4
shift 4

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: > "$work/groups"
: > "$work/users"
names=" "

manage() {
    names="$names$1 "
    printf '%s %s\n' "$1" "$3" >> "$work/groups"
    if [ "$1" = "$user" ] || getent passwd "$1" >/dev/null; then
        printf '%s %s\n' "$1" "$2" >> "$work/users"
    fi
}

manage "$user" "$uid" "$gid"
for entry in "$@"; do
    manage "${entry%%=*}" "${entry#*=}" "${entry#*=}"
done

conflict=0
check_free() {
    while read -r name id; do
        holder=$(getent "$1" "$id" | cut -d: -f1)
        [ -n "$holder" ] || continue
        case "$names" in *" $holder "*) continue ;; esac
        printf 'conflict %s %s %s %s\n' "$1" "$id" "$holder" "$name"
        conflict=1
    done < "$2"
}
check_free group "$work/groups"
check_free passwd "$work/users"
[ "$conflict" -eq 0 ] || exit 3

: > "$work/changes"
record_change() {
    while read -r name id; do
        entry=$(getent "$1" "$name") || continue
        current=$(printf '%s\n' "$entry" | cut -d: -f3)
        [ "$current" = "$id" ] || printf '%s %s %s %s\n' "$1" "$name" "$current" "$id" >> "$work/changes"
    done < "$2"
}
record_change group "$work/groups"
record_change passwd "$work/users"
[ -s "$work/changes" ] || exit 0
sed 's/^/change /' "$work/changes"
[ "$mode" = apply ] || exit 0

# Record owned files before any ID moves, since old and new IDs may be swapped.
# -xdev keeps the walk on the root filesystem. The shared development drive is another mount and is not rewritten.
index=0
while read -r kind name old new; do
    index=$((index + 1))
    test=-gid
    [ "$kind" = group ] || test=-uid
    find / /run /tmp -xdev "$test" "$old" -print0 2>/dev/null > "$work/files.$index" || true
done < "$work/changes"

free_id() {
    # A temporary id breaks a swap. Moving straight to the target id would collide with the account that still holds it.
    id=60000
    while getent "$1" "$id" >/dev/null; do id=$((id + 1)); done
    printf '%s\n' "$id"
}
renumber() {
    if [ "$1" = group ]; then groupmod -g "$3" "$2"; else usermod -u "$3" "$2"; fi
}
while read -r kind name old new; do
    renumber "$kind" "$name" "$(free_id "$kind")"
done < "$work/changes"
while read -r kind name old new; do
    renumber "$kind" "$name" "$new"
done < "$work/changes"

index=0
while read -r kind name old new; do
    index=$((index + 1))
    if [ "$kind" = group ]; then
        xargs -0 -r chgrp -h "$name" < "$work/files.$index"
    else
        xargs -0 -r chown -h "$name" < "$work/files.$index"
    fi
done < "$work/changes"
