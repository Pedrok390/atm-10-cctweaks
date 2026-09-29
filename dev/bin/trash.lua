local args={...}
local PATH="/dev/trash-list"
local DEFAULTS={
  ["minecraft:cobblestone"]=true,
  ["minecraft:dirt"]=true,
}

local function copy(t)
  local r={}
  for k,v in pairs(t or {}) do r[k]=v end
  return r
end

local function loadList()
  if not fs.exists(PATH) then return {version=1,items=copy(DEFAULTS)} end
  local h=fs.open(PATH,"r")
  if not h then return {version=1,items=copy(DEFAULTS)} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" or type(t.items)~="table" then
    return {version=1,items=copy(DEFAULTS)}
  end
  return t
end

local function saveList(t)
  fs.makeDir("/dev")
  local h,err=fs.open(PATH,"w")
  if not h then error("Nao foi possivel salvar trash-list: "..tostring(err),0) end
  h.write(textutils.serialize(t)); h.close()
end

local function validItem(name)
  return type(name)=="string" and name:match("^[%w_%-%.]+:[%w_/%-%.]+$")~=nil
end

local cmd=args[1] or "list"
if cmd=="list" then
  local t=loadList()
  local names={}
  for name,enabled in pairs(t.items) do if enabled then names[#names+1]=name end end
  table.sort(names)
  if #names==0 then print("Blacklist de descarte vazia.") end
  for _,name in ipairs(names) do print(name) end
elseif cmd=="add" then
  local name=args[2]
  if not validItem(name) or args[3] then error("Uso: dev trash add <namespace:item>",0) end
  local t=loadList()
  t.items[name]=true
  saveList(t)
  print("Adicionado ao descarte: "..name)
elseif cmd=="remove" then
  local name=args[2]
  if not validItem(name) or args[3] then error("Uso: dev trash remove <namespace:item>",0) end
  local t=loadList()
  t.items[name]=nil
  saveList(t)
  print("Removido do descarte: "..name)
elseif cmd=="clear" then
  if args[2] then error("Uso: dev trash clear",0) end
  saveList({version=1,items={}})
  print("Blacklist de descarte limpa.")
elseif cmd=="reset" then
  if args[2] then error("Uso: dev trash reset",0) end
  saveList({version=1,items=copy(DEFAULTS)})
  print("Blacklist restaurada para cobblestone e dirt.")
else
  error("Uso: dev trash list | add <item> | remove <item> | clear | reset",0)
end
