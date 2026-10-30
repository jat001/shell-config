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

source ($nu.default-config-dir | path join 'oh-my-posh.nu')

let previous_completer = $env.config.completions.external.completer
$env.config.completions.external.completer = {|place|
    let command = $place.command.0
    if (($command | path basename) not-in ['docker' 'docker.exe']) {
        if $previous_completer != null {
            do $previous_completer $place
        } else {
            null
        }
    } else {
        let response = (try {
            run-external $command '__complete' ...($place.command | skip 1)
                | complete
        } catch { null })
        if $response == null or $response.exit_code != 0 {
            return null
        }
        let lines = ($response.stdout | lines)
        # Docker's last line is ":<bits>". Bit 1 is an error, 8 and 16 ask for file filtering, 4 means no file fallback.
        let directive = (try { $lines | last | str trim | str substring 1.. | into int } catch { 1 })
        if ($directive bit-and 1) != 0 {
            return null
        }
        if ($directive bit-and 24) != 0 {
            return null
        }
        let current = ($place.command | last)
        let value_prefix = if ($current starts-with '--') and ($current | str contains '=') {
            ($current | split row '=' | first) + '='
        } else { '' }
        let candidates = (
            $lines | drop 1 | where {|line| $line != '' }
            | each {|line|
                let fields = ($line | split row "\t" --number 2)
                let value = if $value_prefix != '' and not ($fields.0 starts-with $value_prefix) {
                    $value_prefix + $fields.0
                } else { $fields.0 }
                {value: $value, description: ($fields.1? | default '')}
            }
        )
        if ($candidates | is-empty) and ($directive bit-and 4) == 0 {
            null
        } else {
            $candidates
        }
    }
}
