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


local JOB_PROTOCOL="atm10:job:command"
local STATION_STATUS_PROTOCOL="atm10:station:status"

local function openWireless()
  if not rednet then error("Rednet indisponivel.",0) end
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
      local p=peripheral.wrap(name)
      if p and p.isWireless and p.isWireless() then
        if not rednet.isOpen(name) then rednet.open(name) end
        return name
      end
    end
  end
  error("Wireless modem nao encontrado.",0)
end

local function requestId()
  return tostring(os.getComputerID())..":station:"..
    tostring(os.epoch and os.epoch("utc") or math.floor(os.clock()*1000))
end

local function remoteMessage(action,offset)
  local msg={type="station_command",action=action,requestId=requestId()}
  local name=args[offset]
  if action=="set" then
    local x,y,z=tonumber(args[offset+1]),tonumber(args[offset+2]),tonumber(args[offset+3])
    if not validName(name) or x==nil or y==nil or z==nil or args[offset+4] then
      error("Uso remoto: set <nome> <x> <y> <z>",0)
    end
    msg.name,msg.x,msg.y,msg.z=name,x,y,z
  elseif action=="clear" or action=="show" then
    if not validName(name) or args[offset+1] then error("Uso remoto: "..action.." <nome>",0) end
    msg.name=name
  elseif action=="list" then
    if name then error("Uso remoto: list",0) end
  else
    error("Acao remota invalida: "..tostring(action),0)
  end
  return msg
end

local function printReply(id,msg)
  if msg.ok then
    local suffix=msg.message and (" - "..msg.message) or ""
    print("Turtle "..id..": OK"..suffix)
    if type(msg.stations)=="table" then
      local names={}
      for name in pairs(msg.stations) do names[#names+1]=name end
      table.sort(names)
      for _,name in ipairs(names) do
        local p=msg.stations[name]
        print(string.format("  %s = %.1f, %.1f, %.1f",name,p.x,p.y,p.z))
      end
    end
  else
    printError("Turtle "..id..": "..tostring(msg.error or "falha"))
  end
end

local function runRemote(target,broadcast,action,offset)
  openWireless()
  local msg=remoteMessage(action,offset)
  if broadcast then
    rednet.broadcast(msg,JOB_PROTOCOL)
    local deadline=os.clock()+3
    local count=0
    while os.clock()<deadline do
      local id,reply=rednet.receive(STATION_STATUS_PROTOCOL,0.4)
      if id and type(reply)=="table" and reply.requestId==msg.requestId then
        printReply(id,reply)
        count=count+1
      end
    end
    if count==0 then print("Nenhuma turtle respondeu.") end
  else
    target=tonumber(target)
    if not target then error("ID da turtle invalido.",0) end
    msg.target=target
    if not rednet.send(target,msg,JOB_PROTOCOL) then error("Falha ao enviar para turtle "..target,0) end
    local deadline=os.clock()+5
    while os.clock()<deadline do
      local id,reply=rednet.receive(STATION_STATUS_PROTOCOL,0.5)
      if id==target and type(reply)=="table" and reply.requestId==msg.requestId then
        printReply(id,reply)
        return
      end
    end
    error("Turtle "..target.." nao respondeu.",0)
  end
end

local cmd=args[1] or "list"
if cmd=="remote" then
  local target=args[2]
  local action=args[3]
  if not target or not action then
    error("Uso: dev station remote <turtleId> set/clear/show/list ...",0)
  end
  local shifted={table.unpack(args,4)}
  args=shifted
  runRemote(target,false,action,1)
elseif cmd=="broadcast" then
  local action=args[2]
  if not action then error("Uso: dev station broadcast set/clear/show/list ...",0) end
  local shifted={table.unpack(args,3)}
  args=shifted
  runRemote(nil,true,action,1)
elseif cmd=="set" then
  local name=args[2]
  local x,y,z=tonumber(args[3]),tonumber(args[4]),tonumber(args[5])
  if not validName(name) or not x or not y or not z or args[6] then
    error("Uso: dev station set <nome> <x> <y> <z>",0)
  end
  local t=loadAll()
  t.stations[name]={x=x,y=y,z=z}
  saveAll(t)
  if name=="fuel" and fs.exists("/dev/fuel-map") then fs.delete("/dev/fuel-map") end
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
  error("Uso: dev station set/show/list/clear | remote <id> ... | broadcast ...",0)
end
