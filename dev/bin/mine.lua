-- Rectangular quarry, one block per layer. Home is above the first cell.
-- Coordinates: x = right, z = forward, y = up; direction 0 = forward.
local args = { ... }
local STATE = "/dev/mine-state"
local MARGIN = 32
local TELEMETRY_PROTOCOL = "atm10:mine:telemetry"
local s
local telemetry = { modem = nil, lastGps = -math.huge, gx = nil, gy = nil, gz = nil }

local function wirelessModem()
    if telemetry.modem then return telemetry.modem end
    if not peripheral or not peripheral.getNames then return nil end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local modem = peripheral.wrap(name)
            if modem and type(modem.isWireless) == "function" and modem.isWireless() then
                telemetry.modem = name
                if rednet and rednet.open and not rednet.isOpen(name) then rednet.open(name) end
                return name
            end
        end
    end
    return nil
end

local function updateGps()
    if not gps or not gps.locate then return end
    local now = os.clock()
    if now - telemetry.lastGps < 5 then return end
    telemetry.lastGps = now
    local ok, x, y, z = pcall(gps.locate, 1, false)
    if ok and x then telemetry.gx, telemetry.gy, telemetry.gz = x, y, z end
end

local function sendTelemetry()
    if not s or not rednet or not wirelessModem() then return end
    updateGps()
    local level = turtle.getFuelLevel()
    local free = 0
    for i = 1, 16 do if turtle.getItemCount(i) == 0 then free = free + 1 end end
    rednet.broadcast({
        type = "mine_status",
        id = os.getComputerID(),
        label = os.getComputerLabel() or ("Turtle " .. os.getComputerID()),
        fuel = level,
        fuelLimit = turtle.getFuelLimit(),
        mode = s.mode,
        x = s.x, y = s.y, z = s.z, dir = s.dir,
        gps = telemetry.gx and { x = telemetry.gx, y = telemetry.gy, z = telemetry.gz } or nil,
        width = s.width, length = s.length, depth = s.depth,
        layer = s.layer, cursor = s.cursor,
        cells = s.width * s.length,
        freeSlots = free,
        returnAt = s.x + s.z - s.y + MARGIN + 2,
        minimum = s.minimum,
    }, TELEMETRY_PROTOCOL)
end

local function help()
    print("dev mine - configuracao interativa")
    print("dev mine start <largura> <comprimento> <camadas> [combustivel minimo]")
    print("dev mine resume - retoma uma tarefa salva")
    print("dev mine status - mostra progresso")
    print("dev mine recover-home - apos recolocar na origem e orientacao inicial")
    print("Bau ATRAS, turtle sobre o canto inicial da area.")
    print("Area: para a frente e para a direita; primeira camada logo ABAIXO.")
    print("Desce direto se houver ar na coluna inicial; pode pular blocos isolados.")
    print("Camadas de ar contam no limite de profundidade escolhido.")
    print("O abastecimento aceita qualquer item reconhecido por turtle.refuel(0).")
    print("Recipientes restantes, como o balde da lava, voltam para o mesmo bau.")
    print("Ctrl+T interrompe. Nao mova/gire manualmente; use resume.")
end

local function integer(value, low, high)
    local n = tonumber(value)
    return n and n == n and n % 1 == 0 and n >= low and n <= high and n or nil
end

local function valid(t)
    return type(t) == "table" and t.version == 1
        and integer(t.serial, 0, 1e15) and integer(t.width, 1, 256)
        and integer(t.length, 1, 256) and integer(t.depth, 1, 512)
        and integer(t.minimum, 1, 1e9) and integer(t.layer, 1, t.depth + 1)
        and integer(t.cursor, 0, t.width * t.length)
        and integer(t.x, 0, t.width - 1) and integer(t.z, 0, t.length - 1)
        and integer(t.y, -t.depth, 0) and integer(t.dir, 0, 3)
        and ({ dock=true, travel=true, mine=true, home=true, done=true })[t.mode]
end

local function loadState()
    local best, found
    for _, suffix in ipairs({ ".a", ".b" }) do
        local path = STATE .. suffix
        if fs.exists(path) then
            found = true
            local h = fs.open(path, "r")
            if h then
                local data = h.readAll()
                h.close()
                local ok, t = pcall(textutils.unserialize, data or "")
                if ok and valid(t) and (not best or t.serial > best.serial) then best = t end
            end
        end
    end
    if found and not best then error("Estado salvo ilegivel. Preserve /dev/mine-state.* antes de recuperar.", 0) end
    return best
end

local function save()
    fs.makeDir("/dev")
    s.serial = s.serial + 1
    local path = STATE .. (s.serial % 2 == 0 and ".a" or ".b")
    local h, err = fs.open(path, "w")
    if not h then error("Nao foi possivel salvar progresso: " .. tostring(err), 0) end
    h.write(textutils.serialize(s))
    h.close()
    sendTelemetry()
end

-- Record intention before moving, then the confirmed pose. If power fails
-- between them, recovery requires placing the turtle at its known home.
local function action(name, fn, update)
    s.pending = name
    save()
    local ok, err = fn()
    if ok then update() end
    s.pending = nil
    save()
    return ok, err
end

local function face(dir)
    while s.dir ~= dir do
        local left = (dir - s.dir) % 4 == 3
        local ok, err = action("girar", left and turtle.turnLeft or turtle.turnRight, function()
            s.dir = (s.dir + (left and -1 or 1)) % 4
        end)
        if not ok then error("Nao foi possivel girar: " .. tostring(err), 0) end
    end
end

local function fuel()
    local n = turtle.getFuelLevel()
    return n == "unlimited" and math.huge or n
end

local function emptySlots()
    local n = 0
    for i = 1, 16 do if turtle.getItemCount(i) == 0 then n = n + 1 end end
    return n
end

local function distance()
    return s.x + s.z - s.y
end

local function step(kind)
    local move = kind == "up" and turtle.up or kind == "down" and turtle.down or turtle.forward
    local detect = kind == "up" and turtle.detectUp or kind == "down" and turtle.detectDown or turtle.detect
    local dig = kind == "up" and turtle.digUp or kind == "down" and turtle.digDown or turtle.dig
    for attempt = 1, 12 do
        if detect() then
            if emptySlots() < 2 then error("Sem espaco para remover bloqueio do caminho. Libere 2 slots e use resume.", 0) end
            local dug, reason = dig()
            if not dug then error("Bloco nao pode ser minerado: " .. tostring(reason) .. ". Remova o bloqueio e use resume.", 0) end
            s.dug = (s.dug or 0) + 1
            save()
        end
        local ok, err = action(kind, move, function()
            if kind == "up" then s.y = s.y + 1
            elseif kind == "down" then s.y = s.y - 1
            elseif s.dir == 0 then s.z = s.z + 1
            elseif s.dir == 1 then s.x = s.x + 1
            elseif s.dir == 2 then s.z = s.z - 1
            else s.x = s.x - 1 end
        end)
        if ok then return end
        if fuel() == 0 then error("Combustivel esgotado. Abasteca sem mover a turtle e use resume.", 0) end
        if attempt == 12 then error("Caminho bloqueado: " .. tostring(err) .. ". Libere-o e use resume.", 0) end
        sleep(0.3)
    end
end

local function alongX(x)
    if s.x ~= x then face(s.x < x and 1 or 3) end
    while s.x ~= x do step("forward") end
end

local function alongZ(z)
    if s.z ~= z then face(s.z < z and 0 or 2) end
    while s.z ~= z do step("forward") end
end

local function home()
    -- The previous row is fully cleared, unlike the unfinished current row.
    if s.z > 0 then alongZ(s.z - 1) end
    alongX(0)
    alongZ(0)
    while s.y < 0 do step("up") end
    face(2)
end

local function cell(index)
    local row = math.floor((index - 1) / s.width)
    local col = (index - 1) % s.width
    return row % 2 == 0 and col or s.width - col - 1, row
end

local function travel()
    if s.cursor == 0 then
        -- Reach the cell ABOVE the next layer using the known home shaft.
        while s.y > 1 - s.layer do step("down") end
        if fuel() <= distance() + MARGIN + 2 or emptySlots() <= 2 then
            s.mode = "home"
            save()
            return
        end
        -- Persist the observation before moving/digging. Otherwise a resumed
        -- job could mistake its freshly dug first cell for an empty layer.
        if not s.entering then
            s.entering = s.y > -s.layer and not turtle.detectDown() and "skip" or "mine"
            save()
        end
        if s.y > -s.layer then step("down") end
        if s.entering == "skip" then
            print("Ar na coluna inicial: pulando camada " .. s.layer .. ".")
            s.entering = nil
            if s.layer == s.depth then
                s.cursor = s.width * s.length
                s.mode = "home"
            else
                s.layer = s.layer + 1
                s.dug = 0
            end
            save()
            return
        end
        s.entering = nil
        s.cursor = 1
        save()
    else
        while s.y > -s.layer do step("down") end
        local x, z = cell(s.cursor)
        -- Retrace the already-cleared corridor to the last completed cell.
        if z > 0 then alongZ(z - 1) end
        alongX(x)
        alongZ(z)
    end
    s.mode = "mine"
    save()
end

local function chest()
    -- Turtles can use adjacent chests through suck/drop even when those
    -- blocks are not exposed as generic inventory peripherals.
    local present, block = turtle.inspect()
    if present then
        local tags = block.tags or {}
        if block.name == "minecraft:chest" or block.name == "minecraft:trapped_chest"
            or block.name == "minecraft:barrel" or tags["c:chests"]
            or tags["forge:chests"] or tags["c:barrels"] then return end
    end
    local p = peripheral.wrap("front")
    if p and type(p.list) == "function" and type(p.size) == "function" then return end
    error("Bau nao reconhecido. A frente da turtle agora: "
        .. (present and block.name or "ar")
        .. ". O bau deve ficar atras da ORIENTACAO INICIAL, na mesma altura. Use resume apos corrigir.", 0)
end

local lastWait
local function waitFor(message)
    if lastWait ~= message then print(message); lastWait = message end
    sleep(5)
end

local function unload()
    face(2)
    while true do
        chest() -- Never drop into the world if the chest is absent.
        for i = 1, 16 do
            if turtle.getItemCount(i) > 0 then
                turtle.select(i)
                chest()
                turtle.drop()
            end
        end
        if emptySlots() == 16 then lastWait = nil; return end
        waitFor("Bau cheio. Libere espaco; aguardando na base...")
    end
end

local function refuelAtHome()
    -- Cover a round trip to the farthest cell, plus reserve, regardless of
    -- how small a minimum the user chooses.
    local needed = math.max(s.minimum, 2 * (s.width + s.length + s.depth - 2) + MARGIN)
    local limit = turtle.getFuelLimit()
    if type(limit) == "number" and needed > limit then
        error("Reserva necessaria (" .. needed .. ") excede o tanque (" .. limit .. ").", 0)
    end

    while fuel() < needed do
        chest()
        turtle.select(16)

        -- Prefer inventory peripherals so we can inspect every chest slot.
        -- suck() does not mean "slot 1": a chest may expose another stack first.
        local inv = peripheral.wrap("front")
        local usable = false
        if inv and type(inv.list) == "function" and type(inv.pushItems) == "function"
            and peripheral.getName then
            local turtleName = peripheral.getName(peripheral.wrap("back"))
            if turtleName then
                for slot in pairs(inv.list()) do
                    if inv.pushItems(turtleName, slot, 1, 16) > 0 then
                        if turtle.refuel(0) then
                            usable = turtle.refuel(1)
                            break
                        end
                        -- Not fuel: put it back before trying the next chest slot.
                        turtle.drop()
                    end
                end
            end
        end

        -- Fallback for vanilla chests which are not exposed as inventory
        -- peripherals. This can only test the stack selected by native suck().
        if not usable and turtle.getItemCount(16) == 0 then
            local received = turtle.suck(1)
            usable = received and turtle.refuel(0) and turtle.refuel(1) or false
        end

        -- Return containers (lava bucket -> bucket) or rejected items.
        if turtle.getItemCount(16) > 0 then
            chest()
            turtle.drop()
        end

        if not usable then
            waitFor("Combustivel " .. fuel() .. "/" .. needed
                .. ". Nenhum combustivel acessivel foi encontrado no bau.")
        else
            lastWait = nil
        end
    end
    turtle.select(1)
    print("Combustivel pronto: " .. tostring(turtle.getFuelLevel()) .. " (minimo " .. needed .. ").")
end

local function run()
    while s.mode ~= "done" do
        if s.mode == "home" then
            home()
            s.mode = "dock"
            save()
        elseif s.mode == "dock" then
            unload()
            if s.cursor == s.width * s.length then
                print("Camada " .. s.layer .. " finalizada.")
                if s.layer == s.depth then
                    face(0)
                    s.mode = "done"
                    save()
                    break
                end
                s.layer, s.cursor, s.dug = s.layer + 1, 0, 0
                save()
            end
            refuelAtHome()
            face(0)
            s.mode = "travel"
            save()
        elseif s.mode == "travel" then
            travel()
        elseif s.mode == "mine" then
            if s.cursor == s.width * s.length then
                s.mode = "home"
                save()
            elseif emptySlots() <= 2 or fuel() <= distance() + MARGIN + 2 then
                print("Voltando ao bau para descarregar/abastecer...")
                s.mode = "home"
                save()
            else
                local x, z = cell(s.cursor + 1)
                alongX(x)
                alongZ(z)
                s.cursor = s.cursor + 1
                save()
            end
        end
    end
    print("Mineracao concluida. Turtle na origem; itens no bau.")
end

local function prompt(label, default, maximum)
    while true do
        write(label .. " [" .. default .. "]: ")
        local value = read()
        if value == "" then value = tostring(default) end
        local n = integer(value, 1, maximum)
        if n then return n end
        print("Digite um inteiro entre 1 e " .. maximum .. ".")
    end
end

local function main()
    if args[1] == "help" then help(); return end
    if not turtle then error("Este programa precisa ser executado na mining turtle.", 0) end
    s = loadState()
    if args[1] == "status" then
        if not s then print("Nenhuma mineracao salva."); return end
        print("Area " .. s.width .. "x" .. s.length .. ", " .. s.depth .. " camadas; modo: " .. s.mode)
        print("Camada: " .. math.min(s.layer, s.depth) .. "; celulas: " .. s.cursor .. "/" .. s.width * s.length)
        print("Posicao relativa: " .. s.x .. "," .. s.y .. "," .. s.z .. "; direcao: " .. s.dir)
        print("Combustivel: " .. tostring(turtle.getFuelLevel()))
        sendTelemetry()
        if s.pending then print("Posicao incerta: use recover-home apos recolocar na origem.") end
        return
    end
    if args[1] == "recover-home" then
        if not s or s.mode == "done" then error("Nao ha tarefa ativa para recuperar.", 0) end
        print("Recoloque a turtle na origem, voltada como no inicio, com bau atras.")
        write("Digite ORIGEM para confirmar: ")
        if read() ~= "ORIGEM" then print("Cancelado."); return end
        s.x, s.y, s.z, s.dir, s.pending, s.mode = 0, 0, 0, 0, nil, "dock"
        save()
        print("Origem registrada. Execute dev mine resume.")
        return
    end
    if args[1] == "resume" then
        if not s then error("Nenhuma tarefa salva. Use dev mine.", 0) end
        if s.pending then error("Interrupcao durante movimento: posicao incerta. Use dev mine recover-home.", 0) end
        run()
        return
    end
    if args[1] and args[1] ~= "start" then help(); return end
    if s and s.mode ~= "done" then error("Ja existe uma tarefa. Use dev mine resume ou status.", 0) end
    local width, length, depth, minimum
    if args[1] == "start" then
        width, length = integer(args[2], 1, 256), integer(args[3], 1, 256)
        depth, minimum = integer(args[4], 1, 512), integer(args[5] or 500, 1, 1e9)
        if not width or not length or not depth or not minimum or #args > 5 then help(); error("Dimensoes ou minimo invalidos.", 0) end
    else
        help()
        width = prompt("Largura (direita)", 3, 256)
        length = prompt("Comprimento (frente)", 3, 256)
        depth = prompt("Camadas abaixo da turtle", 3, 512)
        minimum = prompt("Combustivel minimo para sair", 500, 1e9)
    end
    local needed = math.max(minimum, 2 * (width + length + depth - 2) + MARGIN)
    local limit = turtle.getFuelLimit()
    if type(limit) == "number" and needed > limit then error("Minimo/reserva excede a capacidade de " .. limit .. ". Reduza os valores.", 0) end
    print("Area " .. width .. "x" .. length .. "; " .. depth .. " camadas ABAIXO; reserva: " .. needed)
    print("Bau atras; primeiro item acessivel usado para abastecer. Nao mova a turtle durante a tarefa.")
    write("Digite MINERAR para iniciar: ")
    if read() ~= "MINERAR" then print("Cancelado."); return end
    s = { version=1, serial=s and s.serial or 0, width=width, length=length, depth=depth,
        minimum=minimum, layer=1, cursor=0, x=0, y=0, z=0, dir=0, mode="dock", dug=0 }
    save()
    run()
end

main()
