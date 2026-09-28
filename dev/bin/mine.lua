-- Rectangular quarry, one block per layer. Home is above the first cell.
-- Coordinates: x = right, z = forward, y = up; direction 0 = forward.
local args = { ... }
local STATE = "/dev/mine-state"
local FUEL_PLACE = "/dev/fuel-place"
local MARGIN = 32
local TELEMETRY_PROTOCOL = "atm10:mine:telemetry"
local COMMAND_PROTOCOL = "atm10:mine:command"
local s
local save
local telemetry = { modem = nil, lastGps = -math.huge, gx = nil, gy = nil, gz = nil }
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

local function loadFuelPlace()
    if not fs.exists(FUEL_PLACE) then return nil end
    local h = fs.open(FUEL_PLACE, "r")
    if not h then return nil end
    local raw = h.readAll()
    h.close()
    local ok, t = pcall(textutils.unserialize, raw or "")
    if not ok or type(t) ~= "table" or tonumber(t.x) == nil
        or tonumber(t.y) == nil or tonumber(t.z) == nil then return nil end
    return { x = tonumber(t.x), y = tonumber(t.y), z = tonumber(t.z) }
end

local function coord(n)
    return math.floor(tonumber(n) + 0.5)
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
        fuel = level,
        fuelLimit = turtle.getFuelLimit(),
        mode = s.mode,
        x = s.x, y = s.y, z = s.z, dir = s.dir,
        gps = telemetry.gx and { x = telemetry.gx, y = telemetry.gy, z = telemetry.gz } or nil,
        baseGps = s.baseGps,
        gpsDistance = gpsDistance,
        fuelPlace = loadFuelPlace(),
        fuelTrip = fuelBaseDistance(),
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
    print("Bau ATRAS, turtle sobre o canto inicial da area.")
    print("Area: para a frente e para a direita; primeira camada logo ABAIXO.")
    print("Desce direto se houver ar na coluna inicial; pode pular blocos isolados.")
    print("Camadas de ar contam no limite de profundidade escolhido.")
    print("O abastecimento aceita qualquer item reconhecido por turtle.refuel(0).")
    print("Use dev fuel set <x> <y> <z> para definir o bau de combustivel.")
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

local function home()
    returningHome = true
    -- The previous row is fully cleared, unlike the unfinished current row.
    if s.z > 0 then alongZ(s.z - 1) end
    alongX(0)
    alongZ(0)
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
        if fuel() <= returnThreshold() or emptySlots() <= 2 then
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

        -- A lava bucket leaves minecraft:bucket in the selected slot.
        -- Rejected items and containers go back to this same fuel chest.
        if turtle.getItemCount(16) > 0 then
            chest()
            turtle.drop()
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

local function safeRawForward(nav)
    if turtle.detect() then return false, "bloco no caminho" end
    local ok, reason = turtle.forward()
    if not ok then return false, tostring(reason) end
    if nav.heading == 0 then nav.pos.z = nav.pos.z - 1
    elseif nav.heading == 1 then nav.pos.x = nav.pos.x + 1
    elseif nav.heading == 2 then nav.pos.z = nav.pos.z + 1
    else nav.pos.x = nav.pos.x - 1 end
    return true
end

local function rawVertical(nav, target)
    while nav.pos.y < target.y do
        if turtle.detectUp() then return false, "bloco acima" end
        local ok, reason = turtle.up()
        if not ok then return false, tostring(reason) end
        nav.pos.y = nav.pos.y + 1
    end
    while nav.pos.y > target.y do
        if turtle.detectDown() then return false, "bloco abaixo" end
        local ok, reason = turtle.down()
        if not ok then return false, tostring(reason) end
        nav.pos.y = nav.pos.y - 1
    end
    return true
end

local function rawHorizontal(nav, target)
    while nav.pos.x ~= target.x do
        nav.heading = turnRaw(nav.heading, nav.pos.x < target.x and 1 or 3)
        local ok, reason = safeRawForward(nav)
        if not ok then return false, reason end
    end
    while nav.pos.z ~= target.z do
        nav.heading = turnRaw(nav.heading, nav.pos.z < target.z and 2 or 0)
        local ok, reason = safeRawForward(nav)
        if not ok then return false, reason end
    end
    return true
end

local function rawMoveTo(nav, target, verticalFirst)
    local ok, reason
    if verticalFirst then
        ok, reason = rawVertical(nav, target)
        if not ok then return false, reason end
        return rawHorizontal(nav, target)
    end
    ok, reason = rawHorizontal(nav, target)
    if not ok then return false, reason end
    return rawVertical(nav, target)
end

local function fuelStandTargets(place)
    local x,y,z = coord(place.x),coord(place.y),coord(place.z)
    return {
        {x=x-1,y=y,z=z, face=1},
        {x=x+1,y=y,z=z, face=3},
        {x=x,y=y,z=z-1, face=2},
        {x=x,y=y,z=z+1, face=0},
    }
end

local function chooseFuelTarget(place, base)
    local best, bestD
    for _, t in ipairs(fuelStandTargets(place)) do
        local d = math.abs(t.x-base.x)+math.abs(t.y-base.y)+math.abs(t.z-base.z)
        if not bestD or d < bestD then best,bestD=t,d end
    end
    return best, bestD
end

local function refuelAtConfiguredPlace()
    local place = loadFuelPlace()
    if not place then
        -- Backwards compatible fallback: the old base chest is still usable.
        return refuelFromFront(miningFuelNeeded())
    end
    if not s.baseGps then
        error("Bau de combustivel configurado, mas esta tarefa nao possui GPS da base.", 0)
    end

    local base = {x=coord(s.baseGps.x),y=coord(s.baseGps.y),z=coord(s.baseGps.z)}
    local target, trip = chooseFuelTarget(place, base)
    if fuel() >= miningFuelNeeded() then
        return
    end
    if fuel() < trip + 4 then
        error("Combustivel insuficiente para chegar ao bau configurado. Abasteca manualmente uma vez.", 0)
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

    local ok, reason = rawMoveTo(nav, target, true)
    if not ok then
        -- The path already travelled should still be clear, so try to retreat.
        local ret = rawMoveTo(nav, base, false)
        if ret then
            nav.heading = turnRaw(nav.heading, nav.originalHeading)
            s.pending = nil
            save()
        end
        error("Caminho para o bau de combustivel bloqueado (" .. tostring(reason)
            .. "). A turtle nao quebra blocos nesse trajeto."
            .. (ret and "" or " Nao consegui retornar automaticamente; use recover-home."), 0)
    end

    nav.heading = turnRaw(nav.heading, target.face)
    chest()
    local needed = miningFuelNeeded() + trip
    refuelFromFront(needed)

    print("Combustivel pronto. Voltando para a base...")
    ok, reason = rawMoveTo(nav, base, false)
    if not ok then
        error("Caminho de volta da area de combustivel bloqueado: " .. tostring(reason), 0)
    end
    nav.heading = turnRaw(nav.heading, nav.originalHeading)
    s.pending = nil
    save()
    print("Turtle novamente na base apos abastecer.")
end

local function refuelAtHome()
    refuelAtConfiguredPlace()
end

local function run()
    while s.mode ~= "done" do
        remoteGate()
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
            if s.cursor == s.width * s.length then
                s.mode = "home"
                save()
            elseif emptySlots() <= 2 or fuel() <= returnThreshold() then
                s.returnReason = fuel() <= returnThreshold() and "COMBUSTIVEL BAIXO" or "INVENTARIO"
                print("Voltando ao bau: " .. s.returnReason .. "...")
                s.mode = "home"
                save()
            else
                local x, z = cell(s.cursor + 1)
                if alongX(x) and alongZ(z) and s.mode ~= "home" then
                    s.cursor = s.cursor + 1
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
        print("Recoloque a turtle na origem, voltada como no inicio, com bau atras.")
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
        runControlled()
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
    local baseGps = locateGps(2)
    if baseGps then
        print(string.format("Base GPS registrada: %.1f, %.1f, %.1f", baseGps.x, baseGps.y, baseGps.z))
    else
        print("GPS sem sinal. A mineracao continuara usando coordenadas relativas.")
    end
    s = { version=1, serial=s and s.serial or 0, width=width, length=length, depth=depth,
        minimum=minimum, layer=1, cursor=0, x=0, y=0, z=0, dir=0, mode="dock", dug=0,
        baseGps=baseGps }
    save()
    runControlled()
end

main()
