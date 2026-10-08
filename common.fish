set _shell_environment (
    MSYSTEM="$MSYSTEM" \
        WSL_DISTRO_NAME="$WSL_DISTRO_NAME" \
        WSL_INTEROP="$WSL_INTEROP" \
        jq -r \
        --arg platform (uname -s) \
        --arg home $HOME \
        --arg mode platform \
        -f "$HOME/.config/shell/common.jq" \
        "$HOME/.config/shell/common.json"
)
or return

if test -z "$_shell_environment"
    set -e _shell_environment
    return 1
end

jq -r \
    --arg platform $_shell_environment \
    --arg home $HOME \
    --arg mode fish \
    -f "$HOME/.config/shell/common.jq" \
    "$HOME/.config/shell/common.json" |
    source

switch $_shell_environment
    case msys2
        set _shell_theme msys2-fish

    case wsl
        set _shell_theme config
end

if status is-interactive
    set -g fish_color_autosuggestion 8a8a8a --italics

    function _shell_history_search --argument-names direction
        set -l current (commandline)

        if not set -q _shell_history_selected; or test "$current" != "$_shell_history_selected"
            set -g _shell_history_prefix "$current"
            set -g _shell_history_matches (
                history search --null --case-sensitive --prefix -- "$current" |
                    string split0
            )
            set -g _shell_history_index 0
        end

        if test "$direction" = backward
            set -l next (math $_shell_history_index + 1)
            test $next -le (count $_shell_history_matches); or return
            set -g _shell_history_index $next
        else
            test $_shell_history_index -gt 0; or return
            set -g _shell_history_index (math $_shell_history_index - 1)
        end

        if test $_shell_history_index -eq 0
            set -g _shell_history_selected "$_shell_history_prefix"
        else
            set -g _shell_history_selected "$_shell_history_matches[$_shell_history_index]"
        end

        commandline --replace -- "$_shell_history_selected"
        commandline --cursor (string length -- "$_shell_history_selected")
    end

    function fish_user_key_bindings
        bind up '_shell_history_search backward'
        bind down '_shell_history_search forward'
    end

    function _shell_merge_history --on-event fish_preexec
        if not set -q fish_private_mode
            history merge
        end

        set -e \
            _shell_history_selected \
            _shell_history_prefix \
            _shell_history_matches \
            _shell_history_index
    end

    oh-my-posh init fish \
        --config "$HOME/.config/oh-my-posh/$_shell_theme.omp.json" |
        source
end

set -e _shell_environment _shell_theme
