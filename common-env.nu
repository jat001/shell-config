let shared_directory = ($env.HOME | path join '.config' 'shell')

let platform = (
    ^jq -r
        --arg platform $nu.os-info.name
        --arg home $env.HOME
        --arg mode platform
        -f ($shared_directory | path join 'common.jq')
        ($shared_directory | path join 'common.json')
    | str trim
)

if ($platform | is-empty) {
    return
}

# Nushell keeps an empty argument, unlike Windows PowerShell, so the unused WSL inputs can be passed as ''.
let windows_home = if $platform == 'wsl' {
    $shared_directory | path expand | path dirname --num-levels 2
} else {
    ''
}
let mounts = if $platform == 'wsl' { open --raw /proc/self/mounts } else { '' }
let inherited_lc_all = $env.LC_ALL? | default ''
let lc_all = if $platform == 'wsl' and ($inherited_lc_all | is-empty) {
    ^sh -c 'for file in /etc/locale.conf /etc/default/locale; do [ -r "$file" ] || continue; value=$(. "$file"; printf %s "${LC_ALL-}"); [ -n "$value" ] && { printf %s "$value"; break; }; done' | str trim
} else if $platform == 'msys2' and ($inherited_lc_all | is-empty) {
    ^locale -uU | str trim
} else {
    $inherited_lc_all
}

let shared = (
    ^jq
        --arg platform $platform
        --arg home $env.HOME
        --arg windows_home $windows_home
        --arg mounts $mounts
        --arg lc_all $lc_all
        --arg mode plan
        -f ($shared_directory | path join 'common.jq')
        ($shared_directory | path join 'common.json')
    | from json
)

load-env $shared.environment

(
    ^jq -r
        --arg platform $platform
        --arg home $env.HOME
        --arg windows_home $windows_home
        --arg mounts $mounts
        --arg lc_all $lc_all
        --arg mode nu-aliases
        -f ($shared_directory | path join 'common.jq')
        ($shared_directory | path join 'common.json')
    | str replace --all "\r\n" "\n"
    | save --force ($nu.default-config-dir | path join 'common-aliases.nu')
)

# The init script names this system's oh-my-posh binary, so it is kept with the configuration rather than in
# the data directory, which WSL distributions share.
(
    ^oh-my-posh init nu --print --config ($env.HOME | path join '.config' 'oh-my-posh' 'config.omp.jsonc')
    | str replace --all "\r\n" "\n"
    | save --force ($nu.default-config-dir | path join 'oh-my-posh.nu')
)
