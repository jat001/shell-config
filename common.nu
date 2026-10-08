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

source ($nu.default-config-dir | path join 'common-aliases.nu')

oh-my-posh init nu --config (
    $env.HOME | path join '.config' 'oh-my-posh' 'config.omp.json'
)
