local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local TELEMETRY_PROTOCOL="atm10:mine:telemetry"
local STATION_STATUS_PROTOCOL="atm10:station:status"
local STATIONS_PATH="/dev/stations"

if not turtle then error("Este agent deve rodar em uma turtle.",0) end

local function openWireless()
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

local function latestMineState()
  local best
  for _,suffix in ipairs({".a",".b"}) do
    local path="/dev/mine-state"..suffix
    if fs.exists(path) then
      local h=fs.open(path,"r")
      if h then
        local raw=h.readAll(); h.close()
        local ok,t=pcall(textutils.unserialize,raw or "")
        if ok and type(t)=="table" and tonumber(t.serial)
          and (not best or tonumber(t.serial)>tonumber(best.serial or -1)) then
          best=t
        end
      end
    end
  end
  return best
end

local function hasActiveMine()
  local state=latestMineState()
  return state~=nil and state.mode~="done"
end

local function announce(state,extra)
  local msg={
    type="job_agent_status",
    id=os.getComputerID(),
    label=os.getComputerLabel() or ("Turtle "..os.getComputerID()),
    state=state,
    active=hasActiveMine(),
    fuel=turtle.getFuelLevel(),
  }
  if type(extra)=="table" then for k,v in pairs(extra) do msg[k]=v end end
  rednet.broadcast(msg,STATUS_PROTOCOL)
end


local function loadStations()
  if not fs.exists(STATIONS_PATH) then return {version=1,stations={}} end
  local h=fs.open(STATIONS_PATH,"r")
  if not h then return {version=1,stations={}} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" then return {version=1,stations={}} end
  if type(t.stations)~="table" then t.stations={} end
  return t
end

local function saveStations(t)
  fs.makeDir("/dev")
  local h,err=fs.open(STATIONS_PATH,"w")
  if not h then return false,tostring(err) end
  h.write(textutils.serialize(t)); h.close()
  return true
end

local function stationReply(sender,msg,fields)
  fields=fields or {}
  fields.type="station_result"
  fields.requestId=msg.requestId
  rednet.send(sender,fields,STATION_STATUS_PROTOCOL)
end

local function executeStation(sender,msg)
  if type(msg)~="table" or msg.type~="station_command" then return false end
  if msg.target and msg.target~=os.getComputerID() then return false end
  local action=msg.action
  local t=loadStations()

  if action=="set" then
    local name=msg.name
    local x,y,z=tonumber(msg.x),tonumber(msg.y),tonumber(msg.z)
    if type(name)~="string" or not name:match("^[%w_-]+$") or x==nil or y==nil or z==nil then
      stationReply(sender,msg,{ok=false,error="dados invalidos"})
      return true
    end
    t.stations[name]={x=x,y=y,z=z}
    local ok,err=saveStations(t)
    if ok and name=="fuel" and fs.exists("/dev/fuel-map") then fs.delete("/dev/fuel-map") end
    stationReply(sender,msg,{ok=ok,error=err,message=ok and (name.." configurada") or nil})
    return true
  elseif action=="clear" then
    local name=msg.name
    if type(name)~="string" or not name:match("^[%w_-]+$") then
      stationReply(sender,msg,{ok=false,error="nome invalido"})
      return true
    end
    t.stations[name]=nil
    local ok,err=saveStations(t)
    if ok and name=="fuel" and fs.exists("/dev/fuel-map") then fs.delete("/dev/fuel-map") end
    stationReply(sender,msg,{ok=ok,error=err,message=ok and (name.." removida") or nil})
    return true
  elseif action=="show" then
    local p=t.stations[msg.name]
    if not p then stationReply(sender,msg,{ok=false,error="station nao encontrada"})
    else stationReply(sender,msg,{ok=true,stations={[msg.name]=p}}) end
    return true
  elseif action=="list" then
    stationReply(sender,msg,{ok=true,stations=t.stations})
    return true
  end

  stationReply(sender,msg,{ok=false,error="acao invalida"})
  return true
end

local function executeJob(msg)
  if type(msg)~="table" or msg.type~="job_command" then return false end
  if msg.target and msg.target~=os.getComputerID() then return false end
  if msg.command=="discover" then
    announce(hasActiveMine() and "OCUPADA" or "LIVRE",{requestId=msg.requestId})
    return true
  end
  if msg.command=="resume" then
    local state=latestMineState()
    if not state or state.mode=="done" then
      announce("ERRO",{requestId=msg.requestId,error="nenhuma mineracao ativa para retomar"})
      return true
    end
    announce("RETOMANDO",{requestId=msg.requestId,jobId=state.jobId,jobName=state.jobName})
    local ok=shell.execute("/dev/bin/mine.lua","resume")
    if ok then
      announce("LIVRE",{requestId=msg.requestId,lastJobId=state.jobId})
    else
      announce("ERRO",{requestId=msg.requestId,jobId=state.jobId,error="mine.lua resume terminou com erro"})
    end
    return true
  end
  if msg.command=="cancel" then
    local state=latestMineState()
    if not state or state.mode=="done" then
      announce("LIVRE",{requestId=msg.requestId,message="nenhuma tarefa ativa"})
      return true
    end
    announce("CANCELANDO",{requestId=msg.requestId,jobId=state.jobId,jobName=state.jobName})
    local ok=shell.execute("/dev/bin/mine.lua","job-cancel")
    if ok then
      announce("LIVRE",{requestId=msg.requestId,lastJobId=state.jobId,message="tarefa cancelada"})
    else
      announce("ERRO",{requestId=msg.requestId,jobId=state.jobId,error="cancelamento seguro terminou com erro"})
    end
    return true
  end
  if msg.command~="start" then return false end
  if hasActiveMine() then
    announce("OCUPADA",{requestId=msg.requestId,error="tarefa existente"})
    return true
  end
  local w,l,d,m=tonumber(msg.width),tonumber(msg.length),tonumber(msg.depth),tonumber(msg.minimum or 500)
  local sx,sy,sz=tonumber(msg.startX),tonumber(msg.startY),tonumber(msg.startZ)
  if not w or not l or not d or not m or sx==nil or sy==nil or sz==nil then
    announce("ERRO",{requestId=msg.requestId,error="job mine invalido ou sem coordenada inicial"})
    return true
  end
  announce("INICIANDO",{requestId=msg.requestId,jobId=msg.jobId,jobName=msg.jobName})
  local ok=shell.execute("/dev/bin/mine.lua","job-start",tostring(w),tostring(l),tostring(d),tostring(m),tostring(msg.jobId or ""),tostring(msg.jobName or msg.jobId or "job"),tostring(msg.requestId or ""),
    tostring(sx),tostring(sy),tostring(sz))
  if ok then announce("LIVRE",{requestId=msg.requestId,lastJobId=msg.jobId})
  else announce("ERRO",{requestId=msg.requestId,jobId=msg.jobId,error="mine.lua terminou com erro"}) end
  return true
end

openWireless()
announce(hasActiveMine() and "OCUPADA" or "LIVRE")

local last=os.clock()
while true do
  local id,msg=rednet.receive(JOB_PROTOCOL,2)
  if id and (executeStation(id,msg) or executeJob(msg)) then
    last=os.clock()
  elseif os.clock()-last>=10 then
    announce(hasActiveMine() and "OCUPADA" or "LIVRE")
    last=os.clock()
  end
end
