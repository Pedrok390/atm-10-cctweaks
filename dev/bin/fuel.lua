local args={...}
local PATH="/dev/fuel-place"

local function save(t)
  fs.makeDir("/dev")
  local h,err=fs.open(PATH,"w")
  if not h then error("Nao foi possivel salvar fuel place: "..tostring(err),0) end
  h.write(textutils.serialize(t))
  h.close()
end

local function loadCfg()
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
  save({version=1,x=x,y=y,z=z})
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
  print("Configuracao do bau de combustivel removida.")
else
  error("Uso: dev fuel set <x> <y> <z> | show | clear",0)
end
