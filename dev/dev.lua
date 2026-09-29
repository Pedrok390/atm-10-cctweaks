local args = { ... }
local command = args[1] or "help"
local BASE = "https://raw.githubusercontent.com/Pedrok390/atm-10-cctweaks/main/"

if command == "help" then
    print("ATM10 DevKit 0.2.0")
    print("dev help           - Mostra esta ajuda")
    print("dev status         - Estado da instalacao")
    print("dev inspect        - Lista peripherals")
    print("dev inspect <nome> - Mostra tipos e metodos")
    print("dev mine           - Configura a mineracao")
    print("dev mine help      - Ajuda da mining turtle")
    print("dev dashboard      - Painel 4x4 das turtles")
    print("dev jobs           - Job manager (Pocket/PC)")
    print("dev jobs discover  - Procura turtles livres")
    print("dev agent          - Agent de jobs (turtle)")
    print("dev station list   - Lista stations")
    print("dev station set <nome> x y z")
    print("dev station show <nome>")
    print("dev station clear <nome>")
    print("dev station remote <id> set <nome> x y z")
    print("dev station broadcast set <nome> x y z")
    print("dev trash list     - Lista itens descartados")
    print("dev trash add <item>")
    print("dev trash remove <item>")
    print("dev trash clear    - Limpa a blacklist")
    print("dev trash reset    - Restaura cobblestone/dirt")
    print("dev fuel set x y z - Define o bau de combustivel")
    print("dev fuel show      - Mostra o bau configurado")
    print("dev fuel clear     - Remove o bau configurado")
    print("dev fuel map show  - Mostra obstaculos aprendidos")
    print("dev fuel map clear - Limpa o mapa da rota")
    print("dev update         - Atualiza pela branch main")
elseif command == "status" then
    print("ATM10 DevKit 0.2.0")
    print("Computador: " .. os.getComputerID())
    print("Nome: " .. (os.getComputerLabel() or "sem nome"))
    print("Sistema: " .. os.version())
    print("HTTP: " .. ((http and http.get) and "disponivel" or "desativado"))
    for _, path in ipairs({ "/install.lua", "/startup.lua", "/dev/dev.lua", "/dev/bin/inspect.lua", "/dev/bin/mine.lua", "/dev/bin/fuel.lua", "/dev/bin/station.lua", "/dev/bin/trash.lua", "/dev/bin/transport.lua", "/dev/bin/fleet.lua", "/dev/bin/scheduler.lua", "/dev/bin/chunks.lua", "/dev/bin/watchdog.lua", "/dev/bin/jobs.lua", "/dev/bin/agent.lua", "/dev/bin/dashboard.lua" }) do
        print(((fs.exists(path) and not fs.isDir(path)) and "[OK] " or "[AUSENTE] ") .. path)
    end
    print("Peripherals: " .. #peripheral.getNames())
elseif command == "inspect" then
    if not shell.execute("/dev/bin/inspect.lua", table.unpack(args, 2)) then
        error("Falha na inspecao. Confira o nome ou execute dev update.", 0)
    end
elseif command == "trash" then
    if not shell.execute("/dev/bin/trash.lua", table.unpack(args, 2)) then
        error("Falha na configuracao de descarte.", 0)
    end
elseif command == "station" then
    if not shell.execute("/dev/bin/station.lua", table.unpack(args, 2)) then
        error("Falha na configuracao de station.", 0)
    end
elseif command == "fuel" then
    if not shell.execute("/dev/bin/fuel.lua", table.unpack(args, 2)) then
        error("Falha na configuracao de combustivel.", 0)
    end
elseif command == "mine" then
    if not shell.execute("/dev/bin/mine.lua", table.unpack(args, 2)) then
        error("Mineracao interrompida. Leia a mensagem acima; use dev mine status.", 0)
    end
elseif command == "watchdog" then
    if not shell.execute("/dev/bin/watchdog.lua", table.unpack(args, 2)) then
        error("Falha no watchdog.",0)
    end
elseif command == "jobs" then
    if not shell.execute("/dev/bin/jobs.lua", table.unpack(args, 2)) then
        error("Falha no job manager.",0)
    end
elseif command == "agent" then
    if not shell.execute("/dev/bin/agent.lua") then
        error("Falha no agent da turtle.",0)
    end
elseif command == "dashboard" then
    if not shell.execute("/dev/bin/dashboard.lua") then
        error("Falha no dashboard. Verifique monitor e wireless modem.", 0)
    end
elseif command == "update" then
    if not http or not http.get then error("HTTP desativado na configuracao do CC:Tweaked.", 0) end
    print("Buscando instalador atualizado...")
    local nonce = tostring(os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000))
    local response, err, failed = http.get(BASE .. "install.lua?cb=" .. nonce)
    if not response then
        if failed then failed.close() end
        error("Falha na atualizacao: " .. tostring(err), 0)
    end
    local ok, source = pcall(response.readAll)
    response.close()
    if not ok then error(source, 0) end
    if not source or source == "" then error("Instalador vazio; tente novamente.", 0) end
    local installer, syntax = load(source, "@install.lua", "t", _ENV)
    if not installer then error("Instalador invalido: " .. tostring(syntax), 0) end
    installer()
    if turtle then
        print("Reinicie a turtle para ativar/atualizar o job agent em background.")
    end
else
    error("Comando desconhecido: " .. command .. ". Use dev help.", 0)
end
