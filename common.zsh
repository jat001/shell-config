[[ ${1-} == environment || -o interactive ]] || return

source "$HOME/.config/shell/common.sh" || return

if [[ ${1-} == environment ]]; then
    unset _shell_environment _shell_theme
    unfunction _shell_find_path
    return
fi

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000

setopt SHARE_HISTORY HIST_IGNORE_DUPS
unsetopt BEEP HIST_BEEP

if [[ $(bindkey -lL main) != 'bindkey -A emacs main' ]]; then
    bindkey -e
fi

_shell_antidote="${ANTIDOTE_FILE:-$(
    _shell_find_path -f \
        antidote/antidote.zsh \
        zsh-antidote/antidote.zsh \
        zsh/site-functions/antidote.zsh
)}"

if [[ ! -r "$_shell_antidote" ]]; then
    printf '%s\n' 'Antidote initialization file not found; set ANTIDOTE_FILE.' >&2
    return 1
fi

source "$_shell_antidote" || return

# The cache embeds this distribution's install paths, so WSL distributions cannot share one directory.
_shell_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/zsh${WSL_DISTRO_NAME:+/$WSL_DISTRO_NAME}"
mkdir -p "$_shell_cache_dir"

_shell_init_completion() {
    local _cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh${WSL_DISTRO_NAME:+/$WSL_DISTRO_NAME}"
    local _share _context
    local -a _completion_files
    for _share in ${(s.:.)${XDG_DATA_DIRS:-/usr/local/share:/usr/share}}; do
        [[ -d "$_share/zsh/vendor-completions" ]] && fpath+=("$_share/zsh/vendor-completions")
    done
    typeset -gU fpath
    mkdir -p "$_cache"
    # Regular files only: a dangling Docker completion link drops out, and its return changes this context.
    _completion_files=(${^fpath}/_*(N-.))
    _context="${(F)fpath}
${(F)_completion_files}"
    if [[ ! -r "$_cache/completions.context" ||
        "$_context" != "$(<"$_cache/completions.context")" ]]; then
        rm -f -- "$_cache/zcompdump" "$_cache/zcompdump.zwc"
    fi
    autoload -Uz compinit
    compinit -d "$_cache/zcompdump" || return
    print -r -- "$_context" > "$_cache/completions.context"
    typeset -g _shell_completion_ready=1
}

autoload -Uz history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end

bindkey '^[[A' history-beginning-search-backward-end
bindkey '^[[B' history-beginning-search-forward-end
bindkey '^[OA' history-beginning-search-backward-end
bindkey '^[OB' history-beginning-search-forward-end
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[3~' delete-char

eval "$(
    oh-my-posh init zsh \
        --config "$HOME/.config/oh-my-posh/$_shell_theme.omp.json"
)"

ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=245,italic'

_shell_plugin_file="${ZSH_PLUGIN_FILE:-${ZDOTDIR:-$HOME}/.zsh_plugins.txt}"
zstyle ':antidote:bundle' file "$_shell_plugin_file"

_shell_package_completion_dir() {
    local _files _file _directory

    if (( $+commands[pacman] )) &&
        _files="$(pacman -Qql "$1" 2>/dev/null)"; then
        :
    elif (( $+commands[dpkg-query] )) &&
        _files="$(dpkg-query -L "$1" 2>/dev/null)"; then
        :
    elif (( $+commands[rpm] )) &&
        _files="$(rpm -ql "$1" 2>/dev/null)"; then
        :
    else
        return 1
    fi

    for _file in "${(@f)_files}"; do
        [[ -f "$_file" && "${_file:t}" == _* ]] || continue

        for _directory in "$fpath[@]"; do
            if [[ "${_file:h}" == "$_directory" ]]; then
                print -r -- "$_directory"
                return
            fi
        done
    done

    return 1
}

_shell_resolve_plugins() {
    local _line _repo _name _installed _prefix _word _subpath _kind _package_dir
    local -a _words

    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _words=("${(@z)_line}")

        if (( ! ${#_words} )); then
            print -r -- "$_line"
            continue
        fi

        _repo="${(Q)_words[1]}"
        _prefix=

        case "$_repo" in
            using:*)
                _repo="${_repo#using:}"
                _prefix=using:
                ;;

            preset:*)
                print -r -- "$_line"
                continue
                ;;
        esac

        if [[ "$_repo" =~ '^[[:alnum:]_.-]+/[[:alnum:]_.-]+$' ]]; then
            _name="${_repo:t}"
            _name="${_name%.git}"
            _kind=zsh
            _package_dir=

            for _word in "${_words[@]:1}"; do
                _word="${(Q)_word}"
                [[ "$_word" == kind:* ]] && _kind="${_word#kind:}"
            done

            _installed="$(
                _shell_find_path -d \
                    "zsh/plugins/$_name" \
                    "$_name" \
                    "zsh/$_name"
            )"

            # A system package that already dropped _* files onto fpath is used as-is; its path: annotation would miss.
            if [[ -z "$_installed" && "$_kind" == fpath ]]; then
                _package_dir="$(_shell_package_completion_dir "$_name")"

                if [[ -n "$_package_dir" ]]; then
                    _installed="$_package_dir"
                    _words=("${_words[@]:#path:*}")
                fi
            fi

            if [[ -n "$_installed" ]]; then
                for _word in "${_words[@]:1}"; do
                    _word="${(Q)_word}"

                    if [[ "$_word" == path:* ]]; then
                        _subpath="${_word#path:}"

                        if [[ ! -e "$_installed/$_subpath" ]]; then
                            _installed=
                            break
                        fi
                    fi
                done
            fi

            if [[ -n "$_installed" ]]; then
                _words[1]="$_prefix${(q)_installed}"
                _line="${(j: :)_words}"
            fi
        fi

        print -r -- "$_line"
    done < "$_shell_plugin_file"
}

_shell_plugin_lines="$(_shell_resolve_plugins)" || return
_shell_plugins_list="$_shell_cache_dir/plugins.txt"
_shell_plugins_script="$_shell_cache_dir/plugins.zsh"
_shell_plugins_context="$_shell_cache_dir/plugins.context"
_shell_context="$_shell_plugin_file
$_shell_antidote
$(antidote home)"

if [[ ! -r "$_shell_plugins_list" ]] ||
    [[ "$_shell_plugin_lines" != "$(<"$_shell_plugins_list")" ]]; then
    print -r -- "$_shell_plugin_lines" > "$_shell_plugins_list.$$.tmp"
    mv -f -- "$_shell_plugins_list.$$.tmp" "$_shell_plugins_list"
fi

if [[ ! -r "$_shell_plugins_context" ]] ||
    [[ "$_shell_context" != "$(<"$_shell_plugins_context")" ]]; then
    print -r -- "$_shell_context" > "$_shell_plugins_context.$$.tmp"
    mv -f -- "$_shell_plugins_context.$$.tmp" "$_shell_plugins_context"
fi

if [[ ! -r "$_shell_plugins_script" ||
    "$_shell_plugins_list" -nt "$_shell_plugins_script" ||
    "$_shell_plugins_context" -nt "$_shell_plugins_script" ||
    "$_shell_plugin_file" -nt "$_shell_plugins_script" ||
    "$_shell_antidote" -nt "$_shell_plugins_script" ||
    "$ANTIDOTE_CONFIG" -nt "$_shell_plugins_script" ]]; then
    # Git's own directory goes first so its helpers are the ones next to this git, not a hardcoded /usr/bin.
    if PATH="${commands[git]:h}:$PATH" \
        antidote bundle < "$_shell_plugins_list" \
        > "$_shell_plugins_script.$$.tmp"; then
        mv -f -- "$_shell_plugins_script.$$.tmp" "$_shell_plugins_script"
    else
        rm -f -- "$_shell_plugins_script.$$.tmp"
        return 1
    fi
fi

_shell_completion_ready=0
source "$_shell_plugins_script" || return

if (( ! _shell_completion_ready )); then
    _shell_init_completion
fi

if [[ "$_shell_environment" == msys2 ]] && docker --version >/dev/null 2>&1; then
    source <(docker completion zsh)
fi

unfunction _shell_find_path _shell_package_completion_dir _shell_resolve_plugins

unset \
    _shell_environment \
    _shell_theme \
    _shell_antidote \
    _shell_cache_dir \
    _shell_plugin_file \
    _shell_plugin_lines \
    _shell_plugins_list \
    _shell_plugins_script \
    _shell_plugins_context \
    _shell_context \
    _shell_completion_ready
