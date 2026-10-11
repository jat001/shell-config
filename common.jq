def detect_platform:
    . as $os
    | if ($os | ascii_downcase) | . == "windows" or . == "windows_nt" then
        "windows"
      elif ($os | ascii_downcase) == "linux" then
        if [env.WSL_DISTRO_NAME, env.WSL_INTEROP] | any(. != null and length > 0) then
            "wsl"
        else
            empty
        end
      elif $os | test("^(MSYS|CYGWIN|MINGW)") then
        if (env.MSYSTEM // "") | length > 0 then
            "msys2"
        else
            empty
        end
      else
        empty
      end;

if $mode == "platform" then
    $platform | detect_platform
else
    def expand($variables):
        gsub(
            "\\$\\{(?<name>[A-Za-z_][A-Za-z0-9_]*)\\}";
            $variables[.name] // error("Undefined variable: " + .name)
        );

    def native_alias_path:
        if $platform == "windows" and test("^([A-Za-z]:[/\\\\]|[/\\\\]{2})") then
            gsub("/"; "\\")
        else
            .
        end;

    def alias_nu($definition; $variables):
        if $definition | startswith("${HOME}/") then
            "($env.HOME | path join "
            + (
                $definition
                | ltrimstr("${HOME}/")
                | split("/")
                | map(expand($variables) | @json)
                | join(" ")
            )
            + ")"
        else
            @json
        end;

    def distinct:
        reduce .[] as $value (
            [];
            if index($value) == null then
                . + [$value]
            else
                .
            end
        );

    def psquote:
        "'" + gsub("'"; "''") + "'";

    def luaquote:
        @json;

    .common as $common
    | .environments[$platform] as $specific
    | if $specific == null then
        error("Unsupported environment: " + $platform)
      else
        .
      end

    | (($common.environment // {}) + ($specific.environment // {})) as $definitions
    | (env | .PATH = (.PATH // .Path // "") | . + {HOME: $home}) as $inherited

    | (
        reduce ($definitions | to_entries[]) as $entry (
            $inherited;
            . as $variables
            | .[$entry.key] = ($entry.value | expand($variables))
        )
      ) as $variables

    | (
        ($common.path_prepend // []) + ($specific.path_prepend // [])
        | map(expand($variables))
      ) as $prefixes

    | (if $platform == "windows" then ";" else ":" end) as $separator

    | (
        $prefixes + (($variables.PATH // "") | split($separator))
        | map(select(length > 0))
        | distinct
      ) as $path

    | (
        $definitions
        | keys
        | map({key: ., value: $variables[.]})
        | from_entries
        | if ($prefixes | length) > 0 then
            .PATH = ($path | join($separator))
          else
            .
          end
      ) as $environment

    | (($common.aliases // {}) + ($specific.aliases // {})) as $alias_definitions

    | (
        $alias_definitions
        | with_entries(.value |= (expand($variables) | native_alias_path))
      ) as $aliases

    | (
        ($common.links // {}) + ($specific.links // {})
        | with_entries(
            .key |= expand($variables)
            | .value |= expand($variables)
        )
      ) as $links

    | {environment: $environment, aliases: $aliases, links: $links}

    | if $mode == "plan" then
        .environment |= (if has("PATH") then .PATH = $path else . end)

      elif $mode == "sh" then
        (
            .environment
            | to_entries[]
            | "export " + .key + "=" + (.value | @sh)
        ),
        (
            .aliases
            | to_entries[]
            | "alias " + .key + "=" + (.value | @sh)
        )

      elif $mode == "fish" then
        (
            .environment
            | to_entries[]
            | if .key == "PATH" then
                "set -gx PATH " + ($path | map(@json) | join(" "))
              else
                "set -gx " + .key + " " + (.value | @json)
              end
        ),
        (
            .aliases
            | to_entries[]
            | "alias " + .key + " " + (.value | @json)
        )

      elif $mode == "pwsh" then
        (
            .environment
            | to_entries[]
            | "$env:" + .key + " = " + (.value | psquote)
        ),
        (
            .aliases
            | to_entries[]
            | "Set-Alias -Name " + (.key | psquote)
              + " -Value " + (.value | psquote)
        )

      elif $mode == "nu-aliases" then
        (
            .aliases
            | to_entries[]
            | .key as $name
            | "alias " + $name + " = ^"
              + (.value | alias_nu($alias_definitions[$name]; $variables))
        )

      elif $mode == "lua" then
        (
            .environment
            | to_entries[]
            | "os.setenv(" + (.key | luaquote)
              + ", " + (.value | luaquote) + ")"
        ),
        (
            .aliases
            | to_entries[]
            | "os.setalias(" + (.key | luaquote) + ", "
              + (("\"" + .value + "\" $*") | luaquote) + ")"
        )

      else
        error("Unsupported shell output: " + $mode)
      end
end
