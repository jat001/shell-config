# ble.sh sources this file again with "ble" and must return before the interactive bash setup below.
if [ "${1-}" = ble ]; then
    # One millisecond is enough for a lone Esc to leave incremental search without delaying Meta prefixes.
    bind 'set keyseq-timeout 1'

    bleopt edit_bell=
    bleopt history_share=1

    ble-face -s auto_complete fg=245,italic
    ble-face -s region_match none

    for _shell_search in isearch nsearch; do
        ble-bind -m "$_shell_search" -f 'C-[' "$_shell_search/exit"
        ble-bind -m "$_shell_search" -f ESC "$_shell_search/exit"
    done

    unset _shell_search

    ble-bind -m nsearch -f C-m 'nsearch/accept-line'
    ble-bind -m emacs -f up 'history-search-backward hide-status:point=end'
    ble-bind -m emacs -f down 'history-search-forward hide-status:point=end'
    return
fi

[ -n "${BASH_VERSION-}" ] || return
[[ $- == *i* ]] || return

source "$HOME/.config/shell/common.sh" || return

if ! declare -F _init_completion >/dev/null; then
    _shell_bash_completion="$(_shell_find_path -f bash-completion/bash_completion)"
    if [[ -r "$_shell_bash_completion" ]]; then
        source "$_shell_bash_completion"
    fi
    unset _shell_bash_completion
fi

# WSL loads Docker's completion through bash-completion. MSYS2 has no vendor file, so the CLI output is sourced.
if [[ "$_shell_environment" == msys2 ]] && docker --version >/dev/null 2>&1; then
    source <(docker completion bash)
fi

_shell_ble="${BLESH_FILE:-$(
    _shell_find_path -f \
        blesh/ble.sh \
        blesh/out/ble.sh \
        ble.sh/ble.sh \
        ble.sh/out/ble.sh
)}"

if [[ -r "$_shell_ble" ]]; then
    source "$_shell_ble" --noattach
else
    printf '%s\n' 'ble.sh initialization file not found; set BLESH_FILE.' >&2
fi

eval "$(
    oh-my-posh init bash \
        --config "$HOME/.config/oh-my-posh/$_shell_theme.omp.json"
)"

shopt -s histappend
export HISTCONTROL=${HISTCONTROL:+$HISTCONTROL:}ignoredups

unset _shell_environment _shell_ble _shell_theme
unset -f _shell_find_path

[[ ${BLE_VERSION-} ]] && ble-attach
