local args={...}
local PATH="/dev/stations"

local function loadAll()
  if not fs.exists(PATH) then return {version=1,stations={}} end
  local h=fs.open(PATH,"r")
  if not h then return {version=1,stations={}} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" then return {version=1,stations={}} end
  if type(t.stations)~="table" then t.stations={} end
  return t
end

local function saveAll(t)
  fs.makeDir("/dev")
  local h,err=fs.open(PATH,"w")
  if not h then error("Nao foi possivel salvar stations: "..tostring(err),0) end
  h.write(textutils.serialize(t)); h.close()
end

local function validName(name)
  return type(name)=="string" and name:match("^[%w_-]+$")~=nil
end

local cmd=args[1] or "list"
if cmd=="set" then
  local name=args[2]
  local x,y,z=tonumber(args[3]),tonumber(args[4]),tonumber(args[5])
  if not validName(name) or not x or not y or not z or args[6] then
    error("Uso: dev station set <nome> <x> <y> <z>",0)
  end
  local t=loadAll()
  t.stations[name]={x=x,y=y,z=z}
  saveAll(t)
  print(string.format("Station %s = %.1f, %.1f, %.1f",name,x,y,z))
elseif cmd=="show" then
  local name=args[2]
  if not validName(name) or args[3] then error("Uso: dev station show <nome>",0) end
  local s=loadAll().stations[name]
  if not s then print("Station nao encontrada: "..name)
  else print(string.format("%s: %.1f, %.1f, %.1f",name,s.x,s.y,s.z)) end
elseif cmd=="list" then
  local t=loadAll().stations
  local names={}
  for name in pairs(t) do names[#names+1]=name end
  table.sort(names)
  if #names==0 then print("Nenhuma station configurada.") end
  for _,name in ipairs(names) do
    local s=t[name]
    print(string.format("%s = %.1f, %.1f, %.1f",name,s.x,s.y,s.z))
  end
elseif cmd=="clear" then
  local name=args[2]
  if not validName(name) or args[3] then error("Uso: dev station clear <nome>",0) end
  local t=loadAll()
  t.stations[name]=nil
  saveAll(t)
  if name=="fuel" and fs.exists("/dev/fuel-map") then fs.delete("/dev/fuel-map") end
  print("Station removida: "..name)
else
  error("Uso: dev station set/show/list/clear",0)
end
