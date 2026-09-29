-- Rectangular quarry, one block per layer. Home is above the first cell.
-- Coordinates: x = right, z = forward, y = up; direction 0 = forward.
local args = { ... }
local STATE = "/dev/mine-state"
local FUEL_PLACE = "/dev/fuel-place"
local STATIONS = "/dev/stations"
local FUEL_MAP = "/dev/fuel-map"
local MARGIN = 32
local TELEMETRY_PROTOCOL = "atm10:mine:telemetry"
local COMMAND_PROTOCOL = "atm10:mine:command"
local JOB_STATUS_PROTOCOL = "atm10:job:status"
local s
local save
local telemetry = { modem = nil, lastGps = -math.huge, gx = nil, gy = nil, gz = nil }
local routeInfo = { state=nil, replans=0, remaining=nil, known=0 }
local TRASH_PATH = "/dev/trash-list"
local DEFAULT_TRASH = {
    ["minecraft:cobblestone"] = true,
    ["minecraft:dirt"] = true,
}
local trashCache
local returningHome = false

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

local function locateGps(timeout)
    if not gps or not gps.locate then return nil end
    local ok, x, y, z = pcall(gps.locate, timeout or 1, false)
    if ok and x then
        telemetry.gx, telemetry.gy, telemetry.gz = x, y, z
        telemetry.lastGps = os.clock()
        return { x = x, y = y, z = z }
    end
    return nil
end

local function updateGps()
    local now = os.clock()
    if now - telemetry.lastGps < 5 then return end
    telemetry.lastGps = now
    locateGps(1)
end

local function loadStation(name)
    if not fs.exists(STATIONS) then return nil end
    local h=fs.open(STATIONS,"r")
    if not h then return nil end
    local raw=h.readAll()
    h.close()
    local ok,t=pcall(textutils.unserialize,raw or "")
    if not ok or type(t)~="table" or type(t.stations)~="table" then return nil end
    local p=t.stations[name]
    if type(p)~="table" or tonumber(p.x)==nil or tonumber(p.y)==nil or tonumber(p.z)==nil then return nil end
    return {x=tonumber(p.x),y=tonumber(p.y),z=tonumber(p.z)}
end

local function loadFuelPlace()
    return loadStation("fuel")
end

local function validateMiningStations(requireGps)
    local missing = {}
    if not loadStation("unload") then missing[#missing+1] = "unload" end
    if not loadStation("fuel") then missing[#missing+1] = "fuel" end
    if #missing > 0 then
        local commands = {}
        for _, name in ipairs(missing) do
            commands[#commands+1] = "dev station set "..name.." <x> <y> <z>"
        end
        error("Stations obrigatorias ausentes: "..table.concat(missing,", ")
            ..". Configure antes de minerar:\n"..table.concat(commands,"\n"),0)
    end
    if requireGps and (not s or not s.baseGps) then
        error("Esta tarefa nao possui GPS da origem. Use dev mine recover-home na origem antes de retomar.",0)
    end
end

local function coord(n)
    return math.floor(tonumber(n) + 0.5)
end

local function sameFuelPlace(a,b)
    return a and b and tonumber(a.x)==tonumber(b.x)
        and tonumber(a.y)==tonumber(b.y) and tonumber(a.z)==tonumber(b.z)
end

local function countKeys(t)
    local n=0
    for _ in pairs(t or {}) do n=n+1 end
    return n
end

local function loadFuelMap()
    local place=loadFuelPlace()
    if not place or not fs.exists(FUEL_MAP) then return {},0 end
    local h=fs.open(FUEL_MAP,"r")
    if not h then return {},0 end
    local raw=h.readAll()
    h.close()
    local ok,t=pcall(textutils.unserialize,raw or "")
    if not ok or type(t)~="table" or not sameFuelPlace(t.place,place)
        or type(t.blocked)~="table" then return {},0 end
    return t.blocked,countKeys(t.blocked)
end

local function saveFuelMap(blocked)
    local place=loadFuelPlace()
    if not place then return end
    fs.makeDir("/dev")
    local h=fs.open(FUEL_MAP,"w")
    if not h then return end
    h.write(textutils.serialize({version=1,place=place,blocked=blocked}))
    h.close()
    routeInfo.known=countKeys(blocked)
end

local function fuelBaseDistance()
    local p = loadFuelPlace()
    if not p or not s or not s.baseGps then return 0 end
    local bx, by, bz = coord(s.baseGps.x), coord(s.baseGps.y), coord(s.baseGps.z)
    local cx, cy, cz = coord(p.x), coord(p.y), coord(p.z)
    -- The turtle stops beside the chest, not inside it.
    return math.max(0, math.abs(cx-bx) + math.abs(cy-by) + math.abs(cz-bz) - 1)
end

local function sendTelemetry()
    if not s or not rednet or not wirelessModem() then return end
    updateGps()
    local level = turtle.getFuelLevel()
    local gpsDistance
    if s.baseGps and telemetry.gx then
        gpsDistance = math.abs(telemetry.gx - s.baseGps.x)
            + math.abs(telemetry.gy - s.baseGps.y)
            + math.abs(telemetry.gz - s.baseGps.z)
    end
    local free = 0
    for i = 1, 16 do if turtle.getItemCount(i) == 0 then free = free + 1 end end
    rednet.broadcast({
        type = "mine_status",
        id = os.getComputerID(),
        label = os.getComputerLabel() or ("Turtle " .. os.getComputerID()),
        jobId = s.jobId,
        jobName = s.jobName,
        fuel = level,
        fuelLimit = turtle.getFuelLimit(),
        mode = s.mode,
        x = s.x, y = s.y, z = s.z, dir = s.dir,
        gps = telemetry.gx and { x = telemetry.gx, y = telemetry.gy, z = telemetry.gz } or nil,
        baseGps = s.baseGps,
        gpsDistance = gpsDistance,
        fuelPlace = loadFuelPlace(),
        unloadPlace = loadStation("unload"),
        fuelTrip = fuelBaseDistance(),
        routeState = routeInfo.state,
        routeReplans = routeInfo.replans,
        routeRemaining = routeInfo.remaining,
        routeKnown = routeInfo.known,
        width = s.width, length = s.length, depth = s.depth,
        layer = s.layer, cursor = s.cursor,
        cells = s.width * s.length,
        freeSlots = free,
        returnAt = s.x + s.z - s.y + MARGIN + 2,
        returnReason = s.returnReason,
        minimum = s.minimum,
        paused = s.remotePaused or false,
        baseHold = s.remoteHome or false,
        cancelling = s.remoteCancel or false,
        controlState = s.remoteCancel and "CANCELANDO"
            or (s.remoteHome and s.mode == "home" and "RETORNANDO")
            or (s.remoteHome and s.mode == "dock" and "NA BASE")
            or (s.remotePaused and "PAUSADO")
            or nil,
    }, TELEMETRY_PROTOCOL)
end

local function applyControl(msg)
    if type(msg) ~= "table" or msg.type ~= "mine_command" then return false end
    if msg.target and msg.target ~= os.getComputerID() then return false end

    if msg.command == "pause" then
        s.remotePaused = true
        s.returnReason = "PAUSADO"
        print("Comando remoto: PAUSAR.")
    elseif msg.command == "resume" then
        s.remotePaused = false
        s.remoteHome = false
        s.remoteCancel = false
        s.returnReason = nil
        print("Comando remoto: RETOMAR.")
    elseif msg.command == "home" and s.mode ~= "done" then
        s.remotePaused = false
        s.remoteHome = true
        s.remoteCancel = false
        s.returnReason = "COMANDO BASE"
        if s.mode ~= "dock" then s.mode = "home" end
        print("Comando remoto: VOLTAR PARA BASE.")
    elseif msg.command == "cancel" and s.mode ~= "done" then
        s.remotePaused = false
        s.remoteHome = true
        s.remoteCancel = true
        s.returnReason = "CANCELAMENTO"
        if s.mode ~= "dock" then s.mode = "home" end
        print("Comando remoto: CANCELAR. Retornando para a base...")
    else
        return false
    end
    sendTelemetry()
    return true
end

local function controlListener()
    while true do
        local _, msg = rednet.receive(COMMAND_PROTOCOL)
        applyControl(msg)
    end
end

local function remoteGate()
    while s.remotePaused do
        sendTelemetry()
        sleep(0.2)
    end
end

local function help()
    print("dev mine - configuracao interativa")
    print("dev mine start <largura> <comprimento> <camadas> [combustivel minimo]")
    print("dev mine resume - retoma uma tarefa salva")
    print("dev mine status - mostra progresso")
    print("dev mine recover-home - apos recolocar na origem e orientacao inicial")
    print("dev mine cancel - cancela a tarefa quando a turtle esta na base")
    print("Turtle sobre o canto inicial da area; nenhum bau e necessario na origem.")
    print("Area: para a frente e para a direita; primeira camada logo ABAIXO.")
    print("Desce direto se houver ar na coluna inicial; pode pular blocos isolados.")
    print("Camadas de ar contam no limite de profundidade escolhido.")
    print("Ao terminar uma camada, continua para a proxima sem subir.")
    print("So volta a superficie por inventario cheio, combustivel baixo, fim ou comando.")
    print("Cobblestone e dirt sao descartados automaticamente.")
    print("O abastecimento aceita qualquer item reconhecido por turtle.refuel(0).")
    print("Configure antes: dev station set fuel <x> <y> <z> e unload <x> <y> <z>.")
    print("Ao abastecer, volta primeiro a base e depois vai ao bau SEM quebrar blocos.")
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

save = function()
    fs.makeDir("/dev")
    s.serial = s.serial + 1
    local path = STATE .. (s.serial % 2 == 0 and ".a" or ".b")
    local h, err = fs.open(path, "w")
    if not h then error("Nao foi possivel salvar progresso: " .. tostring(err), 0) end
    h.write(textutils.serialize(s))
    h.close()
    sendTelemetry()
end

local function deleteState()
    for _, suffix in ipairs({ ".a", ".b" }) do
        local path = STATE .. suffix
        if fs.exists(path) then fs.delete(path) end
    end
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

local shouldAbortWork

local function face(dir)
    while s.dir ~= dir do
        if shouldAbortWork() then return false end
        local left = (dir - s.dir) % 4 == 3
        local ok, err = action("girar", left and turtle.turnLeft or turtle.turnRight, function()
            s.dir = (s.dir + (left and -1 or 1)) % 4
        end)
        if not ok then error("Nao foi possivel girar: " .. tostring(err), 0) end
    end
    return true
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

local function loadTrashItems()
    if trashCache then return trashCache end
    local items = {}
    for name, enabled in pairs(DEFAULT_TRASH) do if enabled then items[name] = true end end

    if fs.exists(TRASH_PATH) then
        local h = fs.open(TRASH_PATH, "r")
        if h then
            local raw = h.readAll()
            h.close()
            local ok, t = pcall(textutils.unserialize, raw or "")
            if ok and type(t) == "table" and type(t.items) == "table" then
                items = {}
                for name, enabled in pairs(t.items) do
                    if enabled then items[name] = true end
                end
            end
        end
    end
    trashCache = items
    return items
end

local function discardTrash()
    local previous = turtle.getSelectedSlot()
    local discarded = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            local detail = turtle.getItemDetail(i)
            if detail and loadTrashItems()[detail.name] then
                turtle.select(i)
                local count = turtle.getItemCount(i)
                if turtle.dropDown() then discarded = discarded + count end
            end
        end
    end
    turtle.select(previous)
    return discarded
end

local function inventoryFull()
    discardTrash()
    return emptySlots() == 0
end

local function distance()
    return s.x + s.z - s.y
end

local function returnThreshold()
    return distance() + fuelBaseDistance() + MARGIN + 2
end

shouldAbortWork = function()
    remoteGate()
    if returningHome then return false end
    if s.remoteHome or s.mode == "home" then return true end
    if fuel() <= returnThreshold() then
        s.returnReason = "COMBUSTIVEL BAIXO"
        s.mode = "home"
        save()
        print("Combustivel baixo: " .. tostring(fuel())
            .. ". Retornando para a base (limite " .. tostring(returnThreshold()) .. ").")
        return true
    end
    return false
end

local function step(kind)
    local move = kind == "up" and turtle.up or kind == "down" and turtle.down or turtle.forward
    local detect = kind == "up" and turtle.detectUp or kind == "down" and turtle.detectDown or turtle.detect
    local dig = kind == "up" and turtle.digUp or kind == "down" and turtle.digDown or turtle.dig
    for attempt = 1, 12 do
        if shouldAbortWork() then return false end
        if detect() then
            discardTrash()
            if emptySlots() == 0 then
                if not returningHome then
                    s.returnReason = "INVENTARIO"
                    s.mode = "home"
                    save()
                    print("Inventario cheio. Retornando para descarregar...")
                    return false
                end
                error("Inventario cheio durante retorno e caminho bloqueado. Libere espaco e use resume.", 0)
            end
            local dug, reason = dig()
            if not dug then error("Bloco nao pode ser minerado: " .. tostring(reason) .. ". Remova o bloqueio e use resume.", 0) end
            s.dug = (s.dug or 0) + 1
            discardTrash()
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
        if ok then return true end
        if fuel() == 0 then error("Combustivel esgotado. Abasteca sem mover a turtle e use resume.", 0) end
        if attempt == 12 then error("Caminho bloqueado: " .. tostring(err) .. ". Libere-o e use resume.", 0) end
        sleep(0.3)
    end
end

local function alongX(x)
    if s.x ~= x and not face(s.x < x and 1 or 3) then return false end
    while s.x ~= x do if not step("forward") then return false end end
    return true
end

local function alongZ(z)
    if s.z ~= z and not face(s.z < z and 0 or 2) then return false end
    while s.z ~= z do if not step("forward") then return false end end
    return true
end

local function returnToShaft()
    if s.z > 0 and not alongZ(s.z - 1) then return false end
    if not alongX(0) then return false end
    if not alongZ(0) then return false end
    return true
end

local function home()
    returningHome = true
    -- Return through the already-cleared mine to the shaft, then surface.
    returnToShaft()
    while s.y < 0 do step("up") end
    face(2)
    returningHome = false
end

local function cell(index)
    local row = math.floor((index - 1) / s.width)
    local col = (index - 1) % s.width
    return row % 2 == 0 and col or s.width - col - 1, row
end

local function travel()
    if s.cursor == 0 then
        -- Reach the cell ABOVE the next layer using the known home shaft.
        while s.y > 1 - s.layer do if not step("down") then return end end
        if fuel() <= returnThreshold() or inventoryFull() then
            s.returnReason = fuel() <= returnThreshold() and "COMBUSTIVEL BAIXO" or "INVENTARIO"
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
        if s.y > -s.layer and not step("down") then return end
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
        while s.y > -s.layer do if not step("down") then return end end
        local x, z = cell(s.cursor)
        -- Retrace the already-cleared corridor to the last completed cell.
        if z > 0 and not alongZ(z - 1) then return end
        if not alongX(x) then return end
        if not alongZ(z) then return end
    end
    if s.mode ~= "home" then
        s.mode = "mine"
        save()
    end
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
    sendTelemetry()
    sleep(5)
end

local unloadAtConfiguredStation

local function miningFuelNeeded()
    return math.max(s.minimum, 2 * (s.width + s.length + s.depth - 2) + MARGIN)
end

local function refuelFromFront(needed)
    local limit = turtle.getFuelLimit()
    if type(limit) == "number" and needed > limit then
        error("Reserva necessaria (" .. needed .. ") excede o tanque (" .. limit .. ").", 0)
    end

    while fuel() < needed do
        chest()
        turtle.select(16)
        local received = turtle.suck(1)
        local usable = received and turtle.getItemCount(16) > 0 and turtle.refuel(0)

        if usable then
            if not turtle.refuel(1) then
                error("Esse combustivel nao foi aceito pela turtle.", 0)
            end
        end

        -- Rejected items and return containers must go back to this same fuel chest.
        if turtle.getItemCount(16) > 0 then
            chest()
            local detail = turtle.getItemDetail(16)
            local returned = turtle.drop()
            if not returned or turtle.getItemCount(16) > 0 then
                local item = detail and detail.name or "item desconhecido"
                error("Nao consegui devolver "..item.." para a station fuel. Libere espaco no Ender Chest e use resume.", 0)
            end
            if detail and detail.name == "minecraft:bucket" then
                print("Balde vazio devolvido para a station fuel.")
            end
        end

        if not usable then
            waitFor("Nenhum combustivel valido acessivel no bau de combustivel.")
        else
            lastWait = nil
        end
    end
    turtle.select(1)
end

local function headingFromDelta(dx, dz)
    if dx == 1 and dz == 0 then return 1 end
    if dx == -1 and dz == 0 then return 3 end
    if dx == 0 and dz == 1 then return 2 end
    if dx == 0 and dz == -1 then return 0 end
    return nil
end

local function turnRaw(current, target)
    local diff = (target - current) % 4
    if diff == 1 then
        turtle.turnRight()
    elseif diff == 2 then
        turtle.turnRight(); turtle.turnRight()
    elseif diff == 3 then
        turtle.turnLeft()
    end
    return target
end

local function gpsPoint(timeout)
    local p = locateGps(timeout or 2)
    if not p then return nil end
    return { x=coord(p.x), y=coord(p.y), z=coord(p.z) }
end

local function calibrateRawHeading()
    local origin = gpsPoint(2)
    if not origin then return nil, "GPS sem sinal na base." end

    local turns = 0
    for _ = 1, 4 do
        if not turtle.detect() then
            local ok, reason = turtle.forward()
            if ok then
                local now = gpsPoint(2)
                if not now then
                    turtle.back()
                    for _ = 1, turns do turtle.turnLeft() end
                    return nil, "GPS sumiu durante calibracao."
                end
                local moved = headingFromDelta(now.x-origin.x, now.z-origin.z)
                if not moved then
                    turtle.back()
                    for _ = 1, turns do turtle.turnLeft() end
                    return nil, "Nao foi possivel determinar orientacao pelo GPS."
                end
                local original = (moved - turns) % 4
                return { pos=now, heading=moved, originalHeading=original }
            end
        end
        turtle.turnRight()
        turns = turns + 1
    end
    for _ = 1, turns % 4 do turtle.turnLeft() end
    return nil, "Nao ha bloco livre ao redor da base para calibrar a direcao."
end

local function posKey(p)
    return tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)
end

local function manhattan(a, b)
    return math.abs(a.x-b.x) + math.abs(a.y-b.y) + math.abs(a.z-b.z)
end

local function copyPos(p)
    return { x=p.x, y=p.y, z=p.z }
end

-- Prefer vertical movement first. If Y cannot be changed because a block is
-- discovered, A* may still move in X/Z to find another vertical corridor.
local NEIGHBORS = {
    {x=0,y=1,z=0}, {x=0,y=-1,z=0},
    {x=1,y=0,z=0}, {x=-1,y=0,z=0},
    {x=0,y=0,z=1}, {x=0,y=0,z=-1},
}

local function heuristic(p, goals)
    local best
    for _, g in ipairs(goals) do
        local d = manhattan(p, g)
        if not best or d < best then best = d end
    end
    return best or 0
end

local function verticalTie(p, goals)
    local best
    for _, g in ipairs(goals) do
        local dy = math.abs(p.y - g.y)
        if best == nil or dy < best then best = dy end
    end
    return best or 0
end

local function horizontalTie(p, goals)
    local best
    for _, g in ipairs(goals) do
        local d = math.abs(p.x - g.x) + math.abs(p.z - g.z)
        if best == nil or d < best then best = d end
    end
    return best or 0
end

local function reconstruct(came, nodes, key)
    local path = {}
    while came[key] do
        table.insert(path, 1, nodes[key])
        key = came[key]
    end
    return path
end

local function aStar(start, goals, blocked, margin)
    local goalByKey = {}
    local minX,maxX,minY,maxY,minZ,maxZ = start.x,start.x,start.y,start.y,start.z,start.z
    for _, g in ipairs(goals) do
        goalByKey[posKey(g)] = g
        minX,maxX = math.min(minX,g.x),math.max(maxX,g.x)
        minY,maxY = math.min(minY,g.y),math.max(maxY,g.y)
        minZ,maxZ = math.min(minZ,g.z),math.max(maxZ,g.z)
    end
    minX,maxX,minY,maxY,minZ,maxZ =
        minX-margin,maxX+margin,minY-margin,maxY+margin,minZ-margin,maxZ+margin

    local startKey = posKey(start)
    local open = { startKey }
    local inOpen = { [startKey]=true }
    local nodes = { [startKey]=copyPos(start) }
    local came, gScore = {}, { [startKey]=0 }
    local fScore = { [startKey]=heuristic(start,goals) }
    local yTie = { [startKey]=verticalTie(start,goals) }
    local horizontalTieScore = { [startKey]=horizontalTie(start,goals) }

    local expansions, comparisons = 0, 0
    while #open > 0 do
        expansions = expansions + 1
        if expansions % 64 == 0 then sleep(0) end

        local bestIndex = 1
        for i=2,#open do
            comparisons = comparisons + 1
            if comparisons % 256 == 0 then sleep(0) end
            local candidate, currentBest = open[i], open[bestIndex]
            local cf, bf = fScore[candidate] or math.huge, fScore[currentBest] or math.huge
            local cy, by = yTie[candidate] or math.huge, yTie[currentBest] or math.huge
            local ch, bh = horizontalTieScore[candidate] or math.huge, horizontalTieScore[currentBest] or math.huge
            if cf < bf
                or (cf == bf and cy < by)
                or (cf == bf and cy == by and ch < bh) then
                bestIndex = i
            end
        end
        local currentKey = table.remove(open,bestIndex)
        inOpen[currentKey] = nil
        local current = nodes[currentKey]

        if goalByKey[currentKey] then
            return reconstruct(came,nodes,currentKey),goalByKey[currentKey]
        end

        for _, d in ipairs(NEIGHBORS) do
            local n = {x=current.x+d.x,y=current.y+d.y,z=current.z+d.z}
            if n.x>=minX and n.x<=maxX and n.y>=minY and n.y<=maxY
                and n.z>=minZ and n.z<=maxZ then
                local nk = posKey(n)
                if not blocked[nk] then
                    local tentative = gScore[currentKey] + 1
                    if tentative < (gScore[nk] or math.huge) then
                        came[nk] = currentKey
                        nodes[nk] = n
                        gScore[nk] = tentative
                        fScore[nk] = tentative + heuristic(n,goals)
                        yTie[nk] = verticalTie(n,goals)
                        horizontalTieScore[nk] = horizontalTie(n,goals)
                        if not inOpen[nk] then
                            open[#open+1] = nk
                            inOpen[nk] = true
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function headingForStep(from, to)
    local dx,dz = to.x-from.x,to.z-from.z
    if dx==1 and dz==0 then return 1 end
    if dx==-1 and dz==0 then return 3 end
    if dx==0 and dz==1 then return 2 end
    if dx==0 and dz==-1 then return 0 end
    return nil
end

local function markBlocked(blocked,p)
    local k=posKey(p)
    if not blocked[k] then
        blocked[k]=true
        saveFuelMap(blocked)
    end
end

local function tryRawStep(nav, nextPos, blocked)
    local dy = nextPos.y - nav.pos.y
    local ok, reason
    if dy == 1 then
        if turtle.detectUp() then
            markBlocked(blocked,nextPos)
            return false, "bloco acima"
        end
        ok,reason = turtle.up()
    elseif dy == -1 then
        if turtle.detectDown() then
            markBlocked(blocked,nextPos)
            return false, "bloco abaixo"
        end
        ok,reason = turtle.down()
    else
        local h = headingForStep(nav.pos,nextPos)
        if h == nil then return false,"passo invalido" end
        nav.heading = turnRaw(nav.heading,h)
        if turtle.detect() then
            markBlocked(blocked,nextPos)
            return false, "bloco a frente"
        end
        ok,reason = turtle.forward()
    end

    if not ok then
        markBlocked(blocked,nextPos)
        return false,tostring(reason)
    end
    nav.pos = copyPos(nextPos)
    return true
end

local function navigateAStar(nav, goals, blocked)
    local margins = {4,8,16,32,64}
    local replans = 0
    routeInfo.state="CALCULANDO"
    routeInfo.remaining=nil
    routeInfo.known=countKeys(blocked)
    sendTelemetry()

    while replans < 256 do
        replans = replans + 1
        routeInfo.replans=replans
        local path,target
        for _, margin in ipairs(margins) do
            path,target = aStar(nav.pos,goals,blocked,margin)
            if path then break end
        end
        if not path then
            routeInfo.state="SEM ROTA"
            routeInfo.remaining=nil
            sendTelemetry()
            return false,"nenhuma rota encontrada dentro do limite de busca"
        end

        routeInfo.state="NAVEGANDO"
        routeInfo.remaining=#path
        sendTelemetry()

        local changed = false
        for i,nextPos in ipairs(path) do
            local ok,reason = tryRawStep(nav,nextPos,blocked)
            routeInfo.remaining=#path-i
            if i%5==0 then sendTelemetry() end
            if not ok then
                changed = true
                print("Obstaculo detectado em " .. posKey(nextPos)
                    .. ". Recalculando rota...")
                routeInfo.state="RECALCULANDO"
                routeInfo.known=countKeys(blocked)
                s.returnReason = "RECALCULANDO ROTA"
                sendTelemetry()
                break
            end
        end
        if not changed then
            routeInfo.state="CHEGOU"
            routeInfo.remaining=0
            sendTelemetry()
            return true,target
        end
    end
    routeInfo.state="SEM ROTA"
    routeInfo.remaining=nil
    sendTelemetry()
    return false,"limite de recalculos atingido"
end

local function fuelStandTargets(place)
    local x,y,z = coord(place.x),coord(place.y),coord(place.z)
    return {
        {x=x-1,y=y,z=z,face=1},
        {x=x+1,y=y,z=z,face=3},
        {x=x,y=y,z=z-1,face=2},
        {x=x,y=y,z=z+1,face=0},
    }
end

local function calibrateRawHeading()
    local origin = gpsPoint(2)
    if not origin then return nil, "GPS sem sinal na base." end

    local turns = 0
    for _ = 1, 4 do
        if not turtle.detect() then
            local ok = turtle.forward()
            if ok then
                local now = gpsPoint(2)
                turtle.back()
                if not now then
                    for _ = 1, turns do turtle.turnLeft() end
                    return nil, "GPS sumiu durante calibracao."
                end
                local moved = headingFromDelta(now.x-origin.x,now.z-origin.z)
                if not moved then
                    for _ = 1, turns do turtle.turnLeft() end
                    return nil, "Nao foi possivel determinar orientacao pelo GPS."
                end
                local original = (moved-turns)%4
                return {pos=origin,heading=moved,originalHeading=original}
            end
        end
        turtle.turnRight()
        turns = turns + 1
    end
    for _ = 1, turns%4 do turtle.turnLeft() end
    return nil,"Nao ha bloco livre ao redor da base para calibrar a direcao."
end

local function refuelAtConfiguredPlace()
    local place = loadFuelPlace()
    if not place then
        error("Station fuel nao configurada. Use: dev station set fuel <x> <y> <z>",0)
    end
    if not s.baseGps then
        error("Bau de combustivel configurado, mas esta tarefa nao possui GPS da base.", 0)
    end

    local base = {x=coord(s.baseGps.x),y=coord(s.baseGps.y),z=coord(s.baseGps.z)}
    local goals = fuelStandTargets(place)
    local directTrip = math.huge
    for _,g in ipairs(goals) do directTrip=math.min(directTrip,manhattan(base,g)) end
    if fuel() >= miningFuelNeeded() then return end
    if fuel() < directTrip + MARGIN then
        error("Combustivel insuficiente para procurar rota ate o bau configurado. Abasteca manualmente uma vez.", 0)
    end

    s.pending = "fuel-trip"
    save()
    print("Indo ao bau de combustivel sem quebrar blocos...")

    local nav, err = calibrateRawHeading()
    if not nav then
        s.pending = nil
        save()
        error(err, 0)
    end

    local blocked,known = loadFuelMap()
    blocked[posKey({x=coord(place.x),y=coord(place.y),z=coord(place.z)})]=true
    routeInfo.known=math.max(known,countKeys(blocked))
    routeInfo.replans=0
    routeInfo.state="INDO AO COMBUSTIVEL"
    routeInfo.remaining=nil
    sendTelemetry()
    local ok,target = navigateAStar(nav,goals,blocked)
    if not ok then
        local retreat = navigateAStar(nav,{base},blocked)
        if retreat then
            nav.heading = turnRaw(nav.heading,nav.originalHeading)
            s.pending = nil
            save()
        end
        error("Nao encontrei rota livre ate o bau de combustivel: " .. tostring(target)
            .. ". Nenhum bloco foi quebrado.",0)
    end

    nav.heading = turnRaw(nav.heading,target.face)
    chest()
    local routeOut = manhattan(base,target)
    local needed = miningFuelNeeded() + routeOut + MARGIN
    refuelFromFront(needed)

    print("Combustivel pronto. Voltando automaticamente para a origem...")
    s.returnReason = "VOLTANDO A ORIGEM"
    routeInfo.state = "VOLTANDO A ORIGEM"
    routeInfo.remaining = nil
    sendTelemetry()

    ok,target = navigateAStar(nav,{base},blocked)
    if not ok then
        error("Nao encontrei rota livre de volta para a origem: " .. tostring(target),0)
    end

    -- Confirm the physical GPS position before considering the fuel trip done.
    local confirmed = gpsPoint(2)
    if not confirmed or confirmed.x ~= base.x or confirmed.y ~= base.y or confirmed.z ~= base.z then
        local where = confirmed and (confirmed.x..","..confirmed.y..","..confirmed.z) or "sem GPS"
        error("Retorno do combustivel nao confirmou a origem. Posicao atual: "..where
            .."; esperada: "..base.x..","..base.y..","..base.z,0)
    end

    nav.heading = turnRaw(nav.heading, nav.originalHeading)
    routeInfo.state = "NA ORIGEM"
    routeInfo.remaining = 0
    s.returnReason = "NA ORIGEM"
    s.pending = nil
    save()
    sendTelemetry()
    print("Turtle confirmou a origem apos abastecer.")

    -- Keep the confirmation visible briefly before normal mining telemetry resumes.
    sleep(0.5)
    routeInfo.state=nil
    routeInfo.remaining=nil
    routeInfo.replans=0
    s.returnReason=nil
    save()
end

local function refuelAtHome()
    refuelAtConfiguredPlace()
end

unloadAtConfiguredStation = function()
    local place=loadStation("unload")
    if not place then
        error("Station unload nao configurada. Use: dev station set unload <x> <y> <z>",0)
    end
    if not s.baseGps then
        error("Station unload configurada, mas esta tarefa nao possui GPS da base.",0)
    end
    if emptySlots()==16 then return end

    local base={x=coord(s.baseGps.x),y=coord(s.baseGps.y),z=coord(s.baseGps.z)}
    local goals=fuelStandTargets(place)
    s.pending="unload-trip"
    save()
    routeInfo.state="INDO AO UNLOAD"
    routeInfo.replans=0
    routeInfo.remaining=nil
    sendTelemetry()

    local nav,err=calibrateRawHeading()
    if not nav then
        s.pending=nil
        save()
        error(err,0)
    end

    local blocked={ [posKey({x=coord(place.x),y=coord(place.y),z=coord(place.z)})]=true }
    local ok,target=navigateAStar(nav,goals,blocked)
    if not ok then
        local retreat=navigateAStar(nav,{base},blocked)
        if retreat then
            nav.heading=turnRaw(nav.heading,nav.originalHeading)
            s.pending=nil
            save()
        end
        error("Nao encontrei rota livre ate station unload: "..tostring(target),0)
    end

    nav.heading=turnRaw(nav.heading,target.face)
    while true do
        chest()
        for i=1,16 do
            if turtle.getItemCount(i)>0 then
                turtle.select(i)
                chest()
                turtle.drop()
            end
        end
        if emptySlots()==16 then break end
        waitFor("Inventario da station unload cheio. Libere espaco...")
    end
    turtle.select(1)

    routeInfo.state="VOLTANDO A ORIGEM"
    s.returnReason="VOLTANDO A ORIGEM"
    sendTelemetry()
    ok,target=navigateAStar(nav,{base},blocked)
    if not ok then error("Nao encontrei rota de volta da station unload: "..tostring(target),0) end

    local confirmed=gpsPoint(2)
    if not confirmed or confirmed.x~=base.x or confirmed.y~=base.y or confirmed.z~=base.z then
        error("Retorno do unload nao confirmou a origem.",0)
    end
    nav.heading=turnRaw(nav.heading,nav.originalHeading)
    routeInfo.state=nil
    routeInfo.remaining=nil
    routeInfo.replans=0
    s.returnReason=nil
    s.pending=nil
    save()
    print("Descarga concluida; turtle novamente na origem.")
end

local function run()
    while s.mode ~= "done" do
        remoteGate()
        if s.mode == "home" then
            home()
            s.mode = "dock"
            save()
        elseif s.mode == "dock" then
            unloadAtConfiguredStation()
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
            if s.remoteCancel then
                print("Mineracao cancelada com seguranca na base.")
                deleteState()
                return
            end
            if s.remoteHome then
                print("Na base por comando remoto. Aguardando RETOMAR...")
                while s.remoteHome do
                    sendTelemetry()
                    sleep(0.2)
                    if s.remoteCancel then
                        print("Mineracao cancelada com seguranca na base.")
                        deleteState()
                        return
                    end
                end
            end
            face(0)
            s.mode = "travel"
            save()
        elseif s.mode == "travel" then
            travel()
        elseif s.mode == "mine" then
            discardTrash()
            if s.cursor == s.width * s.length then
                print("Camada " .. s.layer .. " finalizada.")
                if s.layer == s.depth then
                    s.returnReason = "CONCLUIDO"
                    s.mode = "home"
                    save()
                elseif fuel() <= returnThreshold() or inventoryFull() then
                    s.returnReason = fuel() <= returnThreshold() and "COMBUSTIVEL BAIXO" or "INVENTARIO"
                    print("Voltando para a superficie: " .. s.returnReason .. "...")
                    s.mode = "home"
                    save()
                elseif returnToShaft() then
                    s.layer = s.layer + 1
                    s.cursor = 0
                    s.dug = 0
                    s.entering = nil
                    s.mode = "travel"
                    save()
                    print("Descendo para a camada " .. s.layer .. " sem voltar a superficie.")
                end
            elseif inventoryFull() or fuel() <= returnThreshold() then
                s.returnReason = fuel() <= returnThreshold() and "COMBUSTIVEL BAIXO" or "INVENTARIO"
                print("Voltando para a superficie: " .. s.returnReason .. "...")
                s.mode = "home"
                save()
            else
                local x, z = cell(s.cursor + 1)
                if alongX(x) and alongZ(z) and s.mode ~= "home" then
                    s.cursor = s.cursor + 1
                    discardTrash()
                    save()
                end
            end
        end
    end
    print("Mineracao concluida. Turtle na origem; itens no bau.")
end

local function runControlled()
    if rednet and parallel and wirelessModem() then
        parallel.waitForAny(run, controlListener)
    else
        run()
    end
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
        updateGps()
        if s.baseGps then
            print(string.format("GPS base: %.1f, %.1f, %.1f", s.baseGps.x, s.baseGps.y, s.baseGps.z))
        else
            print("GPS base: nao registrada")
        end
        if telemetry.gx then
            print(string.format("GPS atual: %.1f, %.1f, %.1f", telemetry.gx, telemetry.gy, telemetry.gz))
        end
        sendTelemetry()
        if s.pending then print("Posicao incerta: use recover-home apos recolocar na origem.") end
        return
    end
    if args[1] == "recover-home" then
        if not s or s.mode == "done" then error("Nao ha tarefa ativa para recuperar.", 0) end
        print("Recoloque a turtle na origem, voltada como no inicio.")
        write("Digite ORIGEM para confirmar: ")
        if read() ~= "ORIGEM" then print("Cancelado."); return end
        s.x, s.y, s.z, s.dir, s.pending, s.mode = 0, 0, 0, 0, nil, "dock"
        local base = locateGps(2)
        if base then
            s.baseGps = base
            print(string.format("GPS da base recalibrado: %.1f, %.1f, %.1f", base.x, base.y, base.z))
        else
            print("GPS sem sinal; mantendo a base GPS anterior.")
        end
        save()
        print("Origem registrada. Execute dev mine resume.")
        return
    end
    if args[1] == "cancel" then
        if not s or s.mode == "done" then
            deleteState()
            print("Nenhuma mineracao ativa.")
            return
        end
        if s.pending then error("Posicao incerta. Recupere a origem antes de cancelar.", 0) end
        if s.x ~= 0 or s.y ~= 0 or s.z ~= 0 or (s.mode ~= "dock" and not s.remoteHome) then
            error("Cancelamento seguro exige a turtle na base. Use o botao BASE, aguarde NA BASE e tente novamente.", 0)
        end
        deleteState()
        print("Mineracao cancelada. Agora voce pode iniciar uma nova tarefa.")
        return
    end
    if args[1] == "resume" then
        if not s then error("Nenhuma tarefa salva. Use dev mine.", 0) end
        if s.pending then error("Interrupcao durante movimento: posicao incerta. Use dev mine recover-home.", 0) end
        validateMiningStations(true)
        runControlled()
        return
    end
    local remoteJob = args[1] == "job-start"
    if args[1] and args[1] ~= "start" and not remoteJob then help(); return end
    if s and s.mode ~= "done" then error("Ja existe uma tarefa. Use dev mine resume ou status.", 0) end
    local width, length, depth, minimum, jobId, jobName, requestId, startX, startY, startZ
    if args[1] == "start" or remoteJob then
        width, length = integer(args[2], 1, 256), integer(args[3], 1, 256)
        depth, minimum = integer(args[4], 1, 512), integer(args[5] or 500, 1, 1e9)
        if remoteJob then
            jobId, jobName, requestId = args[6], args[7], args[8]
            startX, startY, startZ = tonumber(args[9]), tonumber(args[10]), tonumber(args[11])
            if not jobId or jobId == "" or not jobName or jobName == ""
                or not requestId or requestId == ""
                or startX==nil or startY==nil or startZ==nil or #args > 11 then
                error("Job remoto invalido ou sem coordenada inicial.",0)
            end
        elseif #args > 5 then
            help(); error("Dimensoes ou minimo invalidos.",0)
        end
        if not width or not length or not depth or not minimum then help(); error("Dimensoes ou minimo invalidos.", 0) end
    else
        help()
        width = prompt("Largura (direita)", 3, 256)
        length = prompt("Comprimento (frente)", 3, 256)
        depth = prompt("Camadas abaixo da turtle", 3, 512)
        minimum = prompt("Combustivel minimo para sair", 500, 1e9)
    end
    validateMiningStations(false)
    local needed = math.max(minimum, 2 * (width + length + depth - 2) + MARGIN)
    local limit = turtle.getFuelLimit()
    if type(limit) == "number" and needed > limit then error("Minimo/reserva excede a capacidade de " .. limit .. ". Reduza os valores.", 0) end
    print("Area " .. width .. "x" .. length .. "; " .. depth .. " camadas ABAIXO; reserva: " .. needed)
    print("Stations fuel/unload configuradas. Nao mova a turtle durante a tarefa.")
    if remoteJob then
        print("Job remoto recebido: "..tostring(jobName).." ("..tostring(jobId)..")")
    else
        write("Digite MINERAR para iniciar: ")
        if read() ~= "MINERAR" then print("Cancelado."); return end
    end
    local baseGps
    if remoteJob then
        local target={x=coord(startX),y=coord(startY),z=coord(startZ)}
        local current=gpsPoint(2)
        if not current then error("GPS sem sinal; nao consigo navegar ate o inicio do job.",0) end
        local trip=manhattan(current,target)
        if fuel() < trip + MARGIN then
            error("Combustivel insuficiente para chegar ao inicio do job. Precisa de pelo menos "..(trip+MARGIN)..".",0)
        end

        s = { version=1, serial=s and s.serial or 0, width=width, length=length, depth=depth,
            minimum=minimum, layer=1, cursor=0, x=0, y=0, z=0, dir=0, mode="dock", dug=0,
            baseGps=target, jobId=jobId, jobName=jobName, returnReason="INDO AO INICIO" }

        if current.x~=target.x or current.y~=target.y or current.z~=target.z then
            print("Indo para inicio do job em "..target.x..","..target.y..","..target.z.." sem quebrar blocos...")
            routeInfo.state="INDO AO INICIO"
            routeInfo.replans=0
            routeInfo.remaining=nil
            local nav,err=calibrateRawHeading()
            if not nav then error(err,0) end
            local ok,why=navigateAStar(nav,{target},{})
            if not ok then error("Nao encontrei rota ate o inicio do job: "..tostring(why),0) end
            nav.heading=turnRaw(nav.heading,nav.originalHeading)
            local confirmed=gpsPoint(2)
            if not confirmed or confirmed.x~=target.x or confirmed.y~=target.y or confirmed.z~=target.z then
                error("Chegada ao inicio do job nao foi confirmada pelo GPS.",0)
            end
        end
        baseGps=target
        s.returnReason=nil
        routeInfo.state=nil
        routeInfo.remaining=nil
        print("Inicio do job confirmado por GPS: "..target.x..","..target.y..","..target.z)
    else
        baseGps = locateGps(2)
        if baseGps then
            print(string.format("Base GPS registrada: %.1f, %.1f, %.1f", baseGps.x, baseGps.y, baseGps.z))
        else
            error("GPS sem sinal. Stations exigem GPS; corrija o GPS antes de iniciar.",0)
        end
        s = { version=1, serial=s and s.serial or 0, width=width, length=length, depth=depth,
            minimum=minimum, layer=1, cursor=0, x=0, y=0, z=0, dir=0, mode="dock", dug=0,
            baseGps=baseGps, jobId=jobId, jobName=jobName }
    end
    save()
    runControlled()
end

local okMain, errMain = pcall(main)
if not okMain then
    if args[1] == "job-start" and args[8] then
        local modem = wirelessModem()
        if modem and rednet then
            if not rednet.isOpen(modem) then rednet.open(modem) end
            rednet.broadcast({
                type = "job_run_result",
                state = "ERRO",
                requestId = args[8],
                error = tostring(errMain),
            }, JOB_STATUS_PROTOCOL)
        end
    end
    error(errMain, 0)
end
