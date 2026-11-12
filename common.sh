# Empty values are passed on purpose: an inherited WSL or MSYS variable must not reclassify this shell.
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
_shell_lc_all=
if [ "$_shell_environment" = wsl ]; then
    # cd -P resolves the symlink; two parents up is the Windows profile because the repo lives at <profile>/.config/shell.
    _shell_windows_home="$(cd -P "$HOME/.config/shell" && cd ../.. && pwd)"
    if [ "${1-}" = wait ]; then
        _shell_mounts="$(sh "$HOME/.config/shell/wsl-mounts.sh")"
    else
        _shell_mounts="$(</proc/self/mounts)"
    fi
    _shell_lc_all="${LC_ALL-}"
    if [ -z "$_shell_lc_all" ]; then
        for _shell_locale_file in /etc/locale.conf /etc/default/locale; do
            [ -r "$_shell_locale_file" ] || continue
            _shell_lc_all="$(
                . "$_shell_locale_file"
                printf '%s' "${LC_ALL-}"
            )"
            [ -n "$_shell_lc_all" ] && break
        done
        unset _shell_locale_file
    fi
elif [ "$_shell_environment" = msys2 ]; then
    _shell_windows_home="${USERPROFILE-}"
    if [ -z "$_shell_windows_home" ]; then
        # A directly started MSYS2 process can lack all Windows profile variables; ask Windows instead.
        _shell_windows_home="$(
            powershell.exe -NoProfile -NonInteractive -Command \
                '[Environment]::GetFolderPath("UserProfile")' | tr -d '\r'
        )"
    fi
    _shell_windows_home="$(cygpath -u "$_shell_windows_home")" || return
    _shell_lc_all="${LC_ALL-}"
    if [ -z "$_shell_lc_all" ]; then
        _shell_lc_all="$(locale -uU)"
    fi
fi

eval "$(
    jq -r \
        --arg platform "$_shell_environment" \
        --arg home "$HOME" \
        --arg windows_home "$_shell_windows_home" \
        --arg mounts "$_shell_mounts" \
        --arg lc_all "$_shell_lc_all" \
        --arg mode sh \
        -f "$HOME/.config/shell/common.jq" \
        "$HOME/.config/shell/common.json"
)"
unset _shell_windows_home _shell_mounts _shell_lc_all

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

            # The predicate is passed in so one directory list serves both file and directory lookups.
            # shellcheck disable=SC1009,SC1072,SC1073
            if [ "$_test" "$_candidate" ] && [ -r "$_candidate" ]; then
                printf '%s\n' "$_candidate"
                return
            fi
        done
    done

    return 1
}
