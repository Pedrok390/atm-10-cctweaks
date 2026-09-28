local args={...}
local PATH="/dev/fuel-place"
local MAP="/dev/fuel-map"
local STATIONS="/dev/stations"

local function save(t)
  fs.makeDir("/dev")
  local h,err=fs.open(PATH,"w")
  if not h then error("Nao foi possivel salvar fuel place: "..tostring(err),0) end
  h.write(textutils.serialize(t))
  h.close()
end

local function loadStations()
  if not fs.exists(STATIONS) then return {version=1,stations={}} end
  local h=fs.open(STATIONS,"r")
  if not h then return {version=1,stations={}} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" then return {version=1,stations={}} end
  if type(t.stations)~="table" then t.stations={} end
  return t
end

local function saveStations(t)
  fs.makeDir("/dev")
  local h,err=fs.open(STATIONS,"w")
  if not h then error("Nao foi possivel salvar stations: "..tostring(err),0) end
  h.write(textutils.serialize(t)); h.close()
end

local function loadCfg()
  local stations=loadStations()
  if stations.stations.fuel then return stations.stations.fuel end
  if not fs.exists(PATH) then return nil end
  local h=fs.open(PATH,"r")
  if not h then return nil end
  local raw=h.readAll()
  h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" then return nil end
  return t
end

local cmd=args[1] or "show"
if cmd=="set" then
  local x,y,z=tonumber(args[2]),tonumber(args[3]),tonumber(args[4])
  if not x or not y or not z or args[5] then
    error("Uso: dev fuel set <x> <y> <z>",0)
  end
  local stations=loadStations()
  stations.stations.fuel={x=x,y=y,z=z}
  saveStations(stations)
  save({version=1,x=x,y=y,z=z})
  if fs.exists(MAP) then fs.delete(MAP) end
  print(string.format("Bau de combustivel salvo em: %.1f, %.1f, %.1f",x,y,z))
  print("A mining turtle usara este ponto quando precisar abastecer.")
elseif cmd=="show" then
  local t=loadCfg()
  if not t then
    print("Nenhum bau de combustivel configurado.")
    print("Use: dev fuel set <x> <y> <z>")
  else
    print(string.format("Bau de combustivel: %.1f, %.1f, %.1f",t.x,t.y,t.z))
  end
elseif cmd=="clear" then
  if fs.exists(PATH) then fs.delete(PATH) end
  local stations=loadStations()
  stations.stations.fuel=nil
  saveStations(stations)
  if fs.exists(MAP) then fs.delete(MAP) end
  print("Station fuel, configuracao antiga e mapa removidos.")
elseif cmd=="map" and args[2]=="clear" and not args[3] then
  if fs.exists(MAP) then fs.delete(MAP) end
  print("Mapa aprendido da rota de combustivel apagado.")
elseif cmd=="map" and args[2]=="show" and not args[3] then
  if not fs.exists(MAP) then
    print("Nenhum mapa de rota salvo.")
  else
    local h=fs.open(MAP,"r")
    local raw=h and h.readAll() or nil
    if h then h.close() end
    local ok,t=pcall(textutils.unserialize,raw or "")
    local n=0
    if ok and type(t)=="table" and type(t.blocked)=="table" then
      for _ in pairs(t.blocked) do n=n+1 end
    end
    print("Obstaculos conhecidos: "..n)
  end
else
  error("Uso: dev fuel set <x> <y> <z> | show | clear | map show | map clear",0)
end
