_shell_environment="$(
    MSYSTEM="${MSYSTEM-}" \
        WSL_DISTRO_NAME="${WSL_DISTRO_NAME-}" \
        WSL_INTEROP="${WSL_INTEROP-}" \
        jq -r \
        --arg platform "$(uname -s)" \
        --arg home "$HOME" \
        --arg mode platform \
        -f "$HOME/.config/shell/common.jq" \
        "$HOME/.config/shell/common.json"
)" || return

if [ -z "$_shell_environment" ]; then
    unset _shell_environment
    return 1
fi

_shell_windows_home=
_shell_mounts=
if [ "$_shell_environment" = wsl ]; then
    _shell_windows_home="$(cd -P "$HOME/.config/shell" && cd ../.. && pwd)"
    _shell_mounts="$(</proc/self/mounts)"
fi

eval "$(
    jq -r \
        --arg platform "$_shell_environment" \
        --arg home "$HOME" \
        --arg windows_home "$_shell_windows_home" \
        --arg mounts "$_shell_mounts" \
        --arg mode sh \
        -f "$HOME/.config/shell/common.jq" \
        "$HOME/.config/shell/common.json"
)"
unset _shell_windows_home _shell_mounts

case "$_shell_environment" in
    msys2)
        _shell_theme=msys2
        ;;

    wsl)
        _shell_theme=shell-integration
        ;;
esac

_shell_find_path() {
    local _test="$1"
    shift

    local _directories="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    _directories="$_directories:${XDG_DATA_HOME:-$HOME/.local/share}:"

    local _root _relative _candidate

    while [ -n "$_directories" ]; do
        _root="${_directories%%:*}"
        _directories="${_directories#*:}"
        [ -n "$_root" ] || continue

        for _relative in "$@"; do
            _candidate="$_root/$_relative"

            if [ "$_test" "$_candidate" ] && [ -r "$_candidate" ]; then
                printf '%s\n' "$_candidate"
                return
            fi
        done
    done

    return 1
}
