local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local TELEMETRY_PROTOCOL="atm10:mine:telemetry"

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

local function executeJob(msg)
  if type(msg)~="table" or msg.type~="job_command" then return false end
  if msg.target and msg.target~=os.getComputerID() then return false end
  if msg.command=="discover" then
    announce(hasActiveMine() and "OCUPADA" or "LIVRE",{requestId=msg.requestId})
    return true
  end
  if msg.command~="start" then return false end
  if hasActiveMine() then
    announce("OCUPADA",{requestId=msg.requestId,error="tarefa existente"})
    return true
  end
  local w,l,d,m=tonumber(msg.width),tonumber(msg.length),tonumber(msg.depth),tonumber(msg.minimum or 500)
  if not w or not l or not d or not m then
    announce("ERRO",{requestId=msg.requestId,error="job invalido"})
    return true
  end
  announce("INICIANDO",{requestId=msg.requestId,jobId=msg.jobId,jobName=msg.jobName})
  local ok=shell.execute("/dev/bin/mine.lua","job-start",tostring(w),tostring(l),tostring(d),tostring(m),tostring(msg.jobId or ""),tostring(msg.jobName or msg.jobId or "job"))
  if ok then announce("LIVRE",{requestId=msg.requestId,lastJobId=msg.jobId})
  else announce("ERRO",{requestId=msg.requestId,jobId=msg.jobId,error="mine.lua terminou com erro"}) end
  return true
end

openWireless()
announce(hasActiveMine() and "OCUPADA" or "LIVRE")

local last=os.clock()
while true do
  local id,msg=rednet.receive(JOB_PROTOCOL,2)
  if id and executeJob(msg) then
    last=os.clock()
  elseif os.clock()-last>=10 then
    announce(hasActiveMine() and "OCUPADA" or "LIVRE")
    last=os.clock()
  end
end
