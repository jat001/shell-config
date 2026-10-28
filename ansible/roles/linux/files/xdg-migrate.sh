set -eu

# Usage: xdg-migrate.sh check|apply SOURCE SHARED [EXCLUDE...]
# Moves each entry of SOURCE into SHARED when SHARED has no entry of that name.
# Links to SHARED left by earlier versions are skipped.
mode=$1
source_dir=$2
shared_dir=$3
shift 3

[ -d "$source_dir" ] || exit 0
[ "$mode" = check ] || mkdir -p "$shared_dir"

for path in "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    name=${path##*/}
    for exclude in "$@"; do
        [ "$name" != "$exclude" ] || continue 2
    done
    target=$shared_dir/$name
    if [ -L "$path" ] && [ "$(readlink -- "$path")" = "$target" ]; then
        continue
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        printf 'conflict %s %s\n' "$path" "$target"
        continue
    fi
    if [ "$mode" = check ]; then
        printf 'move %s %s\n' "$path" "$target"
        continue
    fi
    mv -- "$path" "$target"
    printf 'move %s %s\n' "$path" "$target"
done
