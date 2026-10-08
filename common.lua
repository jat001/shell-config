local home = os.getenv("HOME")

os.setenv("CLINK_CUSTOMPROMPT", assert(clink.getprompts("oh-my-posh")))

local function read_shared(mode, platform)
    local command = 'jq -r --arg platform "' .. platform
        .. '" --arg home "' .. home
        .. '" --arg mode ' .. mode
        .. ' -f "' .. home .. '/.config/shell/common.jq" "'
        .. home .. '/.config/shell/common.json"'

    local process = assert(io.popen(command))
    local script = process:read("*a")
    process:close()

    return script
end

clink.oninject(function()
    local platform = read_shared("platform", os.getenv("OS") or ""):match("%S+")
    if not platform then
        return
    end

    os.execute("mode con cp select=65001 >nul")

    local f = io.popen(
        'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" /v Path'
    )

    local machine = string.explode(
        os.expandenv(f:read("*a"):match("REG_%S+%s+([^\r\n]+)")),
        ";"
    )
    f:close()

    local sys, path = {}, {}

    for _, p in ipairs(machine) do
        sys[p:lower()] = true
    end

    for _, p in ipairs(string.explode(os.getenv("PATH"), ";")) do
        if not sys[p:lower()] then
            table.insert(path, p)
        end
    end

    for _, p in ipairs(machine) do
        table.insert(path, p)
    end

    os.setenv("PATH", table.concat(path, ";"))
    assert(load(read_shared("lua", platform)))()
end)
