local args={...}
local LOG="/dev/watchdog.log"
local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local MINE_TELEMETRY="atm10:mine:telemetry"
local MINE_COMMAND="atm10:mine:command"
local MINE_ACK="atm10:mine:control:ack"
local TRANSPORT_COMMAND="atm10:transport:command"
local TRANSPORT_ACK="atm10:transport:control:ack"
local STUCK_SECONDS=180
local OFFLINE_SECONDS=45
local RECOVERY_WAIT=45
local turtles={}

local function now() return os.epoch and os.epoch("utc")/1000 or os.clock() end
local function writeLog(s)
  local h=fs.open(LOG,"a")
  if h then h.writeLine(tostring(math.floor(now())).." "..s); h.close() end
  print(s)
end
local function showLog()
  if not fs.exists(LOG) then print("Nenhum evento do watchdog."); return end
  local h=fs.open(LOG,"r"); if not h then return end
  local lines={}
  while true do local s=h.readLine(); if not s then break end; lines[#lines+1]=s end
  h.close()
  for i=math.max(1,#lines-29),#lines do print(lines[i]) end
end
local function openWireless()
  for _,n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n)=="modem" then
      local p=peripheral.wrap(n)
      if p and p.isWireless and p.isWireless() then if not rednet.isOpen(n) then rednet.open(n) end return end
    end
  end
  error("Wireless modem nao encontrado.",0)
end
local function sig(msg,kind)
  if kind=="mine" then
    local p=msg.position or msg.pos or {}
    return table.concat({msg.layer or "",msg.index or msg.progress or "",p.x or msg.x or "",p.y or msg.y or "",p.z or msg.z or ""},":")
  end
  return table.concat({msg.state or "",msg.delivered or "",msg.trips or ""},":")
end
local function touch(id,msg,kind)
  local t=turtles[id] or {lastChange=now()}
  t.lastSeen=now();t.kind=kind;t.jobId=msg.jobId;t.jobName=msg.jobName;t.state=msg.state or t.state
  local s=sig(msg,kind)
  if s~=t.signature then t.signature=s;t.lastChange=now();t.recovery=nil;t.alert=nil end
  turtles[id]=t
end
local function sendControl(id,protocol,ack,command)
  local req="watchdog:"..id..":"..command..":"..math.floor(now()*1000)
  local typ=protocol==MINE_COMMAND and "mine_command" or "transport_command"
  rednet.send(id,{type=typ,target=id,command=command,requestId=req},protocol)
  local deadline=os.clock()+2
  while os.clock()<deadline do
    local sender,msg=rednet.receive(ack,0.25)
    if sender==id and type(msg)=="table" and msg.requestId==req then return true end
  end
  return false
end
local function recover(id,t)
  if t.kind=="mine" then
    if not t.recovery then
      t.recovery={stage="resume",at=now()};writeLog("#"..id.." STUCK; tentando resume")
      sendControl(id,MINE_COMMAND,MINE_ACK,"resume")
    elseif t.recovery.stage=="resume" and now()-t.recovery.at>=RECOVERY_WAIT then
      t.recovery={stage="home",at=now()};writeLog("#"..id.." ainda sem progresso; tentando home")
      sendControl(id,MINE_COMMAND,MINE_ACK,"home")
    elseif t.recovery.stage=="home" and now()-t.recovery.at>=RECOVERY_WAIT then
      t.recovery={stage="failed",at=now()};t.alert="NEEDS_RESCUE"
      writeLog("#"..id.." NEEDS_RESCUE; recovery automatico interrompido")
    end
  elseif t.kind=="transport" and not t.recovery then
    t.recovery={stage="paused",at=now()};t.alert="NEEDS_RESCUE"
    writeLog("#"..id.." transport STUCK; solicitando pausa segura")
    sendControl(id,TRANSPORT_COMMAND,TRANSPORT_ACK,"pause")
  end
end
local function receiver()
  while true do
    local id,msg,protocol=rednet.receive()
    if id and type(msg)=="table" then
      if protocol==MINE_TELEMETRY and msg.type=="mine_status" then touch(id,msg,"mine")
      elseif protocol==STATUS_PROTOCOL and msg.type=="transport_status" then touch(id,msg,"transport")
      elseif protocol==STATUS_PROTOCOL and msg.type=="job_agent_status" then
        local t=turtles[id] or {lastChange=now()}
        t.lastSeen=now();t.agentActive=msg.active;t.agentState=msg.state;turtles[id]=t
      end
    end
  end
end
local function monitor()
  while true do
    rednet.broadcast({type="job_command",command="discover"},JOB_PROTOCOL)
    local n=now()
    for id,t in pairs(turtles) do
      if t.lastSeen and n-t.lastSeen>OFFLINE_SECONDS and t.alert~="OFFLINE" then
        t.alert="OFFLINE";writeLog("#"..id.." OFFLINE ha "..math.floor(n-t.lastSeen).."s")
      elseif t.lastSeen and n-t.lastSeen<=OFFLINE_SECONDS and t.kind and t.lastChange
        and n-t.lastChange>STUCK_SECONDS and t.alert~="OFFLINE" then
        t.alert=t.alert or "STUCK";recover(id,t)
      end
    end
    sleep(5)
  end
end

if args[1]=="log" then showLog(); return end
openWireless()
print("Watchdog ativo: stuck="..STUCK_SECONDS.."s offline="..OFFLINE_SECONDS.."s")
parallel.waitForAny(receiver,monitor)
