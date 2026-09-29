local JOBS="/dev/jobs"
local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local TELEMETRY_PROTOCOL="atm10:mine:telemetry"
local turtles={}
local pending={}
local PRIORITY={high=3,normal=2,low=1}

local function openWireless()
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
      local p=peripheral.wrap(name)
      if p and p.isWireless and p.isWireless() then
        if not rednet.isOpen(name) then rednet.open(name) end
        return
      end
    end
  end
  error("Wireless modem nao encontrado.",0)
end

local function loadJobs()
  if not fs.exists(JOBS) then return {version=1,nextId=1,jobs={}} end
  local h=fs.open(JOBS,"r"); if not h then return {version=1,nextId=1,jobs={}} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" or type(t.jobs)~="table" then return {version=1,nextId=1,jobs={}} end
  return t
end

local function saveJobs(t)
  local tmp=JOBS..".scheduler"
  local h=assert(fs.open(tmp,"w"))
  h.write(textutils.serialize(t)); h.close()
  if fs.exists(JOBS) then fs.delete(JOBS) end
  fs.move(tmp,JOBS)
end

local function now()
  return os.epoch and os.epoch("utc")/1000 or os.clock()
end

local function queued(t)
  local q={}
  for _,j in ipairs(t.jobs) do
    if j.state=="FILA" then q[#q+1]=j end
  end
  table.sort(q,function(a,b)
    local pa=PRIORITY[a.priority or "normal"] or 2
    local pb=PRIORITY[b.priority or "normal"] or 2
    if pa~=pb then return pa>pb end
    local qa=tonumber(a.queuedAt) or tonumber(a.id) or 0
    local qb=tonumber(b.queuedAt) or tonumber(b.id) or 0
    return qa<qb
  end)
  return q
end

local function freeTurtles()
  local ids={}
  local n=now()
  for id,t in pairs(turtles) do
    if n-(t.seen or 0)<=20 and not t.active and not pending[id] then ids[#ids+1]=id end
  end
  table.sort(ids)
  return ids
end

local function messageFor(j,id)
  local kind=j.type or "mine"
  return {
    type="job_command",command="start",target=id,
    requestId="scheduler:"..tostring(j.id)..":"..tostring(math.floor(now()*1000)),
    jobId=tostring(j.id),jobName=j.name,jobType=kind,
    width=j.width,length=j.length,depth=j.depth,minimum=j.minimum,
    startX=j.start and j.start.x or nil,startY=j.start and j.start.y or nil,startZ=j.start and j.start.z or nil,
    source=j.source,destination=j.destination,item=j.item,quantity=j.quantity,
  }
end

local function dispatch()
  local data=loadJobs()
  local q=queued(data)
  local free=freeTurtles()
  local changed=false
  for i=1,math.min(#q,#free) do
    local j,id=q[i],free[i]
    local msg=messageFor(j,id)
    j.turtleId=id
    j.state="DESPACHANDO"
    j.dispatchedAt=now()
    j.schedulerRequest=msg.requestId
    pending[id]={jobId=tostring(j.id),requestId=msg.requestId,since=now()}
    changed=true
    saveJobs(data)
    if not rednet.send(id,msg,JOB_PROTOCOL) then
      j.state="FILA"; j.turtleId=nil; j.schedulerRequest=nil
      pending[id]=nil
      saveJobs(data)
    end
  end
  if changed then sleep(0) end
end

local function updateJob(jobId,fn)
  local data=loadJobs()
  for _,j in ipairs(data.jobs) do
    if tostring(j.id)==tostring(jobId) then fn(j); saveJobs(data); return end
  end
end

local function receiveLoop()
  while true do
    local id,msg,protocol=rednet.receive()
    if id and type(msg)=="table" then
      if protocol==STATUS_PROTOCOL and msg.type=="job_agent_status" then
        turtles[id]=turtles[id] or {}
        local t=turtles[id]
        t.seen=now(); t.active=msg.active; t.state=msg.state; t.label=msg.label
        if not msg.active and pending[id] and now()-pending[id].since>12 then
          local p=pending[id]; pending[id]=nil
          updateJob(p.jobId,function(j)
            if j.state=="DESPACHANDO" then j.state="FILA"; j.turtleId=nil; j.schedulerRequest=nil end
          end)
        end
      elseif protocol==STATUS_PROTOCOL and msg.requestId then
        local p=pending[id]
        if p and msg.requestId==p.requestId then
          if msg.state=="INICIANDO" then
            updateJob(p.jobId,function(j) j.state="INICIANDO" end)
          elseif msg.state=="OCUPADA" or msg.state=="ERRO" then
            pending[id]=nil
            updateJob(p.jobId,function(j)
              j.state="FILA"; j.turtleId=nil; j.schedulerRequest=nil
              j.lastError=msg.error or msg.state
            end)
          end
        end
        if msg.type=="transport_status" and msg.jobId then
          turtles[id]=turtles[id] or {}
          turtles[id].seen=now(); turtles[id].active=msg.state~="CONCLUIDO" and msg.state~="CANCELADO"
          updateJob(msg.jobId,function(j)
            j.state=msg.state or j.state
            if msg.state=="CONCLUIDO" or msg.state=="SEM_CARGA" or msg.state=="ORIGEM_ESGOTADA" or msg.state=="CANCELADO" then
              pending[id]=nil
            end
          end)
        end
      elseif protocol==TELEMETRY_PROTOCOL and msg.type=="mine_status" then
        turtles[id]=turtles[id] or {}
        turtles[id].seen=now(); turtles[id].active=true
        if msg.jobId then
          pending[id]=nil
          updateJob(msg.jobId,function(j) j.state="MINERANDO" end)
        end
      end
    end
  end
end

local function tickLoop()
  while true do
    rednet.broadcast({type="job_command",command="discover"},JOB_PROTOCOL)
    sleep(1)
    dispatch()
    sleep(2)
  end
end

openWireless()
print("Scheduler ATM10 ativo. Ctrl+T para sair.")
parallel.waitForAny(receiveLoop,tickLoop)
