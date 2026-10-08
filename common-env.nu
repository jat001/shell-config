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

let shared = (
    ^jq
        --arg platform $platform
        --arg home $env.HOME
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
        --arg mode nu-aliases
        -f ($shared_directory | path join 'common.jq')
        ($shared_directory | path join 'common.json')
    | str replace --all "\r\n" "\n"
    | save --force ($nu.default-config-dir | path join 'common-aliases.nu')
)
