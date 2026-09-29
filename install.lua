-- ATM10 DevKit installer v1
local BASE = "https://raw.githubusercontent.com/Pedrok390/atm-10-cctweaks/main/"
local MARKER = "-- ATM10 DevKit startup v1"
local BACKUP = "/startup.devkit-backup.lua"
local files = { "dev/dev.lua", "dev/bin/inspect.lua", "dev/bin/mine.lua", "dev/bin/dashboard.lua", "dev/bin/fuel.lua", "dev/bin/station.lua", "dev/bin/trash.lua", "dev/bin/jobs.lua", "dev/bin/agent.lua", "install.lua", "startup.lua" }

local function read(path)
    local h, err = fs.open(path, "r")
    if not h then error(err or ("Nao foi possivel ler " .. path), 0) end
    local ok, data = pcall(h.readAll)
    h.close()
    if not ok then error(data, 0) end
    return data
end

local function write(path, data)
    local h, err = fs.open(path, "w")
    if not h then error(err or ("Nao foi possivel salvar " .. path), 0) end
    local ok, result = pcall(h.write, data)
    h.close()
    if not ok then error(result, 0) end
end

local function install()
    if not http or not http.get then error("HTTP desativado na configuracao do CC:Tweaked.", 0) end
    if fs.exists("/startup") and not fs.isDir("/startup") then
        error("Existe /startup sem extensao. Renomeie esse programa antes de instalar.", 0)
    end
    for _, dir in ipairs({ "/dev", "/dev/bin" }) do
        if fs.exists(dir) and not fs.isDir(dir) then error(dir .. " precisa ser um diretorio.", 0) end
    end
    local downloaded, previous = {}, {}
    for _, name in ipairs(files) do
        local path = "/" .. name
        if fs.isDir(path) or fs.isReadOnly(path) then error("Destino indisponivel: " .. path, 0) end
        if fs.exists(path) then previous[name] = read(path) end
        print("Baixando " .. name .. "...")
        local response, err, failed = http.get(BASE .. name)
        if not response then
            if failed then failed.close() end
            error("Falha no download: " .. tostring(err), 0)
        end
        local ok, body = pcall(response.readAll)
        response.close()
        if not ok then error(body, 0) end
        if not body or body == "" then error("Arquivo vazio: " .. name, 0) end
        local chunk, syntax = load(body, "@" .. name, "t", _ENV)
        if not chunk then error("Lua invalido em " .. name .. ": " .. tostring(syntax), 0) end
        downloaded[name] = body
    end
    local oldStartup = previous["startup.lua"]
    local preserve = oldStartup and oldStartup:sub(1, #MARKER) ~= MARKER
    if preserve and fs.exists(BACKUP) then
        error("Backup ja existe: " .. BACKUP .. ". Preserve ou renomeie esse arquivo antes de instalar.", 0)
    end
    fs.makeDir("/dev/bin")
    if preserve then
        write(BACKUP, oldStartup)
        print("Startup anterior preservado em " .. BACKUP)
    end
    -- Validate every download before replacing installed programs.
    local touched = {}
    local ok, err = pcall(function()
        for _, name in ipairs(files) do
            touched[#touched + 1] = name
            write("/" .. name, downloaded[name])
        end
    end)
    if not ok then
        for i = #touched, 1, -1 do
            local name = touched[i]
            local restored, restoreErr = pcall(function()
                if previous[name] then write("/" .. name, previous[name])
                elseif fs.exists("/" .. name) then fs.delete("/" .. name) end
            end)
            if not restored then printError("Falha ao restaurar " .. name .. ": " .. tostring(restoreErr)) end
        end
        error("Instalacao interrompida: " .. tostring(err), 0)
    end
    shell.setAlias("dev", "/dev/dev.lua")
    print("[OK] DevKit instalado. Digite: dev help")
    print("Atualizacoes: dev update. Inicializacao automatica no proximo boot.")
end

local ok, err = pcall(install)
if not ok then error("[DevKit] " .. tostring(err), 0) end
