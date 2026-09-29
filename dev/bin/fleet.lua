local args={...}
local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local TELEMETRY_PROTOCOL="atm10:mine:telemetry"
local turtles={}
local selected=1
local notice=""
local noticeAt=0

local function setNotice(s)
  notice=tostring(s or "")
  noticeAt=os.clock()
end

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

local function now()
  return os.epoch and os.epoch("utc")/1000 or os.clock()
end

local function trim(s,n)
  s=tostring(s or "")
  if #s<=n then return s end
  if n<=1 then return s:sub(1,n) end
  return s:sub(1,n-1).."~"
end

local function put(x,y,s)
  local w,h=term.getSize()
  if y<1 or y>h or x>w then return end
  term.setCursorPos(math.max(1,x),y)
  term.write(trim(s,w-x+1))
end

local function sorted()
  local list={}
  for _,t in pairs(turtles) do list[#list+1]=t end
  table.sort(list,function(a,b) return a.id<b.id end)
  return list
end

local function age(t)
  return math.max(0,math.floor(now()-(t.seen or now())))
end

local function kind(t)
  if t.transport then return "transport" end
  if t.mine then return "mine" end
  return t.active and "job" or "-"
end

local function state(t)
  if t.transport then return t.transport.state or "TRANSPORT" end
  if t.mine then
    if t.mine.controlState then return t.mine.controlState end
    return t.mine.mode or "MINE"
  end
  return t.state or (t.active and "OCUPADA" or "LIVRE")
end

local function progress(t)
  if t.transport then
    local d=t.transport.delivered or 0
    if t.transport.target then return d.."/"..t.transport.target.." v"..(t.transport.trips or 0) end
    return d.." v"..(t.transport.trips or 0)
  end
  if t.mine then
    local m=t.mine
    local cells=tonumber(m.cells) or 0
    local cursor=tonumber(m.cursor) or 0
    local layer=tonumber(m.layer) or 0
    local depth=tonumber(m.depth) or 0
    if cells>0 then
      local pct=math.floor(math.min(100,(cursor/cells)*100))
      return "L"..layer.."/"..depth.." "..pct.."%"
    end
    return "L"..layer.."/"..depth
  end
  return ""
end

local function render()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  local w,h=term.getSize()
  put(1,1,"FROTA ATM10  turtles:"..#sorted())
  put(1,2,string.rep("-",w))

  local list=sorted()
  if selected>#list then selected=math.max(1,#list) end
  local rows=math.max(1,h-7)
  local first=math.max(1,math.min(selected,math.max(1,#list-rows+1)))
  for row=1,rows do
    local idx=first+row-1
    local t=list[idx]
    if not t then break end
    local prefix=idx==selected and ">" or " "
    local online=age(t)<=20 and "" or " OFF"
    put(1,2+row,string.format("%s#%d %-9s %-11s %s%s",
      prefix,t.id,trim(kind(t),9),trim(state(t),11),trim(progress(t),12),online))
  end

  local t=list[selected]
  local y=h-3
  put(1,y,string.rep("-",w))
  if t then
    local name=(t.mine and t.mine.jobName) or (t.transport and t.transport.jobName) or t.label or "-"
    put(1,y+1,"#"..t.id.." "..trim(name,w-5).." fuel:"..tostring(t.fuel or "?"))
    if t.transport then
      put(1,y+2,trim((t.transport.source or "?").." -> "..(t.transport.destination or "?")..
        (t.transport.item and (" ["..t.transport.item.."]") or ""),w))
    elseif t.mine then
      local m=t.mine
      put(1,y+2,string.format("pos %s,%s,%s  livres:%s",
        tostring(m.x or "?"),tostring(m.y or "?"),tostring(m.z or "?"),tostring(m.freeSlots or "?")))
    else
      put(1,y+2,"Sem job ativo. Ultimo sinal: "..age(t).."s")
    end
  else
    put(1,y+1,"Nenhuma turtle encontrada.")
    put(1,y+2,"Aguardando agents wireless...")
  end
  if notice~="" and os.clock()-noticeAt<5 then
    put(1,h,trim(notice,w))
  else
    put(1,h,"UP/DOWN | J job | P pausa | H base | C canc | R")
  end
end

local function touch(id)
  local t=turtles[id]
  if not t then t={id=id}; turtles[id]=t end
  t.seen=now()
  return t
end

local function receiveLoop()
  while true do
    local id,msg,protocol=rednet.receive()
    if id and type(msg)=="table" then
      local t=touch(id)
      if protocol==STATUS_PROTOCOL then
        if msg.type=="transport_status" then
          t.transport=msg
          t.mine=nil
          t.transportActive=msg.state~="CONCLUIDO" and msg.state~="SEM_CARGA"
            and msg.state~="ORIGEM_ESGOTADA" and msg.state~="CANCELADO"
          t.active=t.transportActive
          t.state=msg.state
          t.fuel=msg.fuel or t.fuel
        elseif msg.type=="job_agent_status" then
          t.label=msg.label or t.label
          t.fuel=msg.fuel
          t.active=msg.active
          if msg.active then
            t.state=msg.state
          elseif t.transport and not t.transportActive then
            t.state="LIVRE"
          else
            t.state=msg.state
          end
        end
      elseif protocol==TELEMETRY_PROTOCOL and msg.type=="mine_status" then
        t.mine=msg
        t.transport=nil
        t.transportActive=false
        t.active=true
        t.label=msg.label or t.label
        t.fuel=msg.fuel
      end
    end
  end
end

local function refreshLoop()
  while true do
    render()
    sleep(0.5)
  end
end

local function selectedTurtle()
  return sorted()[selected]
end

local function runJobs(...)
  local argv={...}
  local ok,err=pcall(function()
    shell.run("/dev/bin/jobs.lua",table.unpack(argv))
  end)
  if not ok then setNotice("ERRO: "..tostring(err)) end
  rednet.broadcast({type="job_command",command="discover"},JOB_PROTOCOL)
end

local function chooseJob(turtleId)
  if not fs.exists("/dev/jobs") then setNotice("Nenhum job salvo."); return end
  local h=fs.open("/dev/jobs","r")
  if not h then setNotice("Nao consegui abrir /dev/jobs"); return end
  local raw=h.readAll(); h.close()
  local ok,data=pcall(textutils.unserialize,raw or "")
  if not ok or type(data)~="table" or type(data.jobs)~="table" or #data.jobs==0 then
    setNotice("Nenhum job salvo."); return
  end

  term.clear()
  put(1,1,"INICIAR JOB NA TURTLE #"..turtleId)
  put(1,2,"Digite numero/nome ou vazio para voltar:")
  local y=3
  local _,height=term.getSize()
  for _,j in ipairs(data.jobs) do
    if y>=height then break end
    put(1,y,string.format("#%s %-9s %s",tostring(j.id),tostring(j.type or "mine"),tostring(j.name)))
    y=y+1
  end
  term.setCursorPos(1,math.min(height,y+1))
  term.write("> ")
  local key=read()
  if key=="" then setNotice("Inicio cancelado."); return end

  local chosen
  for _,j in ipairs(data.jobs) do
    if tostring(j.id)==key or j.name==key then chosen=j; break end
  end
  if not chosen then setNotice("Job nao encontrado: "..key); return end
  if chosen.turtleId and tonumber(chosen.turtleId)~=tonumber(turtleId) then
    setNotice("Job reatribuido para #"..turtleId)
  end
  runJobs("assign",tostring(chosen.id),tostring(turtleId))
  runJobs("start",tostring(chosen.id))
  setNotice("Job "..tostring(chosen.name).." enviado para #"..turtleId)
end

local function control(command)
  local t=selectedTurtle()
  if not t then setNotice("Selecione uma turtle."); return end
  if age(t)>20 then setNotice("Turtle #"..t.id.." esta offline."); return end
  if t.transportActive then
    if command=="home" then
      setNotice("Transport nao usa BASE; pause ou cancele com seguranca.")
      return
    end
    runJobs("transport-control",tostring(t.id),command)
    setNotice(command.." enviado ao transport #"..t.id)
    return
  end
  if not t.mine and not t.active then
    setNotice("Turtle #"..t.id.." nao esta minerando.")
    return
  end
  runJobs(command,tostring(t.id))
  setNotice(command.." enviado para #"..t.id)
end

local function inputLoop()
  while true do
    local _,key=os.pullEvent("key")
    local list=sorted()
    if key==keys.q then return
    elseif key==keys.up then selected=math.max(1,selected-1)
    elseif key==keys.down then selected=math.min(math.max(1,#list),selected+1)
    elseif key==keys.r then
      rednet.broadcast({type="job_command",command="discover"},JOB_PROTOCOL)
      setNotice("Descoberta enviada.")
    elseif key==keys.j then
      local t=selectedTurtle()
      if t then chooseJob(t.id) else setNotice("Selecione uma turtle.") end
    elseif key==keys.p then
      local t=selectedTurtle()
      if t and ((t.mine and t.mine.paused) or (t.transport and t.transport.state=="PAUSADO")) then
        control("resume")
      else
        control("pause")
      end
    elseif key==keys.h then control("home")
    elseif key==keys.c then control("cancel")
    end
    render()
  end
end

openWireless()
rednet.broadcast({type="job_command",command="discover"},JOB_PROTOCOL)
parallel.waitForAny(receiveLoop,refreshLoop,inputLoop)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1,1)
