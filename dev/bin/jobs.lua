local args={...}
local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local MINE_COMMAND="atm10:mine:command"
local CONTROL_ACK_PROTOCOL="atm10:mine:control:ack"
local TELEMETRY_PROTOCOL="atm10:mine:telemetry"
local PATH="/dev/jobs"

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
  error("Wireless modem nao encontrado neste computador.",0)
end

local function loadJobs()
  if not fs.exists(PATH) then return {version=1,nextId=1,jobs={}} end
  local h=fs.open(PATH,"r")
  if not h then return {version=1,nextId=1,jobs={}} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" or type(t.jobs)~="table" then
    return {version=1,nextId=1,jobs={}}
  end
  t.nextId=tonumber(t.nextId) or 1
  return t
end

local function saveJobs(t)
  fs.makeDir("/dev")
  local h,err=fs.open(PATH,"w")
  if not h then error("Nao foi possivel salvar jobs: "..tostring(err),0) end
  h.write(textutils.serialize(t)); h.close()
end

local function findJob(t,key)
  key=tostring(key or "")
  for _,j in ipairs(t.jobs) do
    if tostring(j.id)==key or j.name==key then return j end
  end
  return nil
end

local function integer(v,lo,hi)
  local n=tonumber(v)
  return n and n%1==0 and n>=lo and n<=hi and n or nil
end

local function discover(seconds)
  seconds=tonumber(seconds) or 3
  local found={}
  local req=tostring(os.getComputerID())..":discover:"..tostring(os.epoch and os.epoch("utc") or math.floor(os.clock()*1000))
  rednet.broadcast({type="job_command",command="discover",requestId=req},JOB_PROTOCOL)
  local deadline=os.clock()+seconds
  while os.clock()<deadline do
    local id,msg=rednet.receive(STATUS_PROTOCOL,0.5)
    if id and type(msg)=="table" and msg.type=="job_agent_status"
      and (msg.requestId==req or msg.requestId==nil) then
      found[id]=msg
    end
  end
  return found
end

local function printTurtles(found)
  local ids={}
  for id in pairs(found) do ids[#ids+1]=id end
  table.sort(ids)
  if #ids==0 then print("Nenhuma turtle agent encontrada.") return end
  for _,id in ipairs(ids) do
    local t=found[id]
    print(string.format("%d  %-16s  %s  fuel=%s",
      id,tostring(t.label or "?"),tostring(t.state or "?"),tostring(t.fuel or "?")))
  end
end

local function listJobs(t)
  if #t.jobs==0 then print("Nenhum job salvo.") return end
  for _,j in ipairs(t.jobs) do
    local start=j.start and (j.start.x..","..j.start.y..","..j.start.z) or "sem-coord"
    print(string.format("#%s %-10s %-12s %sx%sx%s inicio=%s turtle=%s estado=%s",
      j.id,j.type or "mine",j.name,j.width,j.length,j.depth,start,j.turtleId or "-",j.state or "CRIADO"))
  end
end

local function sendMine(target,command)
  target=tonumber(target)
  if not target then error("ID da turtle invalido.",0) end

  local req=tostring(os.getComputerID())..":"..command..":"..
    tostring(os.epoch and os.epoch("utc") or math.floor(os.clock()*1000))

  rednet.send(target,{
    type="mine_command",target=target,command=command,requestId=req
  },MINE_COMMAND)

  local deadline=os.clock()+1.5
  while os.clock()<deadline do
    local id,reply=rednet.receive(CONTROL_ACK_PROTOCOL,0.25)
    if id==target and type(reply)=="table" and reply.requestId==req then
      print("Turtle confirmou comando: "..command)
      return
    end
  end

  if command=="resume" or command=="cancel" then
    print("Mineracao ativa nao respondeu; tentando estado salvo pelo agent...")
    rednet.send(target,{
      type="job_command",target=target,command=command,requestId=req
    },JOB_PROTOCOL)

    local waitUntil=os.clock()+5
    while os.clock()<waitUntil do
      local id,reply=rednet.receive(STATUS_PROTOCOL,0.5)
      if id==target and type(reply)=="table" and reply.requestId==req then
        if reply.state=="ERRO" then
          error("Turtle: "..tostring(reply.error or "erro desconhecido"),0)
        end
        print("Turtle: "..tostring(reply.state or "OK")
          ..(reply.message and (" - "..reply.message) or ""))
        return
      end
    end
    error("Turtle nao respondeu ao "..command..".",0)
  end

  print("Comando enviado sem confirmacao: "..command)
end

local function startJob(t,j)
  if not j.turtleId then error("Job sem turtle. Use dev jobs assign <job> <id>.",0) end
  local kind=j.type or "mine"
  if kind=="mine" and (type(j.start)~="table" or tonumber(j.start.x)==nil or tonumber(j.start.y)==nil or tonumber(j.start.z)==nil) then
    error("Job antigo sem coordenada inicial. Recrie com: dev jobs create mine <nome> <w> <l> <d> <x> <y> <z> [minFuel]",0)
  elseif kind=="transport" and (not j.source or not j.destination) then
    error("Job transport invalido.",0)
  elseif kind~="mine" and kind~="transport" then
    error("Tipo de job nao suportado: "..tostring(kind),0)
  end
  local req=tostring(os.getComputerID())..":"..tostring(os.epoch and os.epoch("utc") or math.floor(os.clock()*1000))
  local msg={
    type="job_command",command="start",target=j.turtleId,requestId=req,
    jobId=tostring(j.id),jobName=j.name,jobType=kind,
    width=j.width,length=j.length,depth=j.depth,minimum=j.minimum,
    startX=j.start and j.start.x or nil,
    startY=j.start and j.start.y or nil,
    startZ=j.start and j.start.z or nil,
    source=j.source,destination=j.destination,
  }
  if not rednet.send(j.turtleId,msg,JOB_PROTOCOL) then error("Nao consegui enviar o job para a turtle.",0) end
  print("Job enviado. Aguardando a turtle realmente iniciar...")
  local deadline=os.clock()+10
  local accepted=false
  while os.clock()<deadline do
    local sender,reply,protocol=rednet.receive(nil,0.5)
    if protocol==STATUS_PROTOCOL and type(reply)=="table" and reply.requestId==req then
      if reply.state=="INICIANDO" then
        accepted=true
        j.state="INICIANDO"; saveJobs(t)
        print("Turtle aceitou; aguardando inicio do job...")
      elseif reply.state=="OCUPADA" or reply.state=="ERRO" then
        j.state=reply.state; saveJobs(t)
        error("Turtle nao iniciou: "..tostring(reply.error or reply.state),0)
      end
    elseif protocol==TELEMETRY_PROTOCOL and sender==j.turtleId and type(reply)=="table"
      and tostring(reply.jobId or "")==tostring(j.id) then
      j.state="MINERANDO"; saveJobs(t)
      print("Job de mineracao iniciado. Telemetria recebida.")
      return
    elseif protocol==STATUS_PROTOCOL and sender==j.turtleId and type(reply)=="table"
      and reply.type=="transport_status" and tostring(reply.jobId or "")==tostring(j.id) then
      j.state=reply.state or "TRANSPORTANDO"; saveJobs(t)
      print("Transport ativo: "..tostring(j.state))
      return
    end
  end
  j.state=accepted and "INICIANDO" or "ENVIADO"
  saveJobs(t)
  if accepted then
    print("Turtle aceitou, mas nao enviou telemetria em 10s. Verifique dev mine status nela.")
  else
    print("Sem confirmacao em 10s; job ficou como ENVIADO.")
  end
end

local function createJob(t,kind,name,w,l,d,x,y,z,m)
  if kind~="mine" then error("Use createTransport para jobs transport.",0) end
  if not name or name=="" or name:find("%s") then error("Nome do job deve ser uma palavra.",0) end
  if findJob(t,name) then error("Ja existe job com esse nome.",0) end
  w,l,d=integer(w,1,256),integer(l,1,256),integer(d,1,512)
  x,y,z=tonumber(x),tonumber(y),tonumber(z)
  m=integer(m or 500,1,1000000000)
  if not w or not l or not d or x==nil or y==nil or z==nil or not m then
    error("Uso: dev jobs create mine <nome> <largura> <comprimento> <profundidade> <x> <y> <z> [minFuel]",0)
  end
  local j={
    id=t.nextId,type="mine",name=name,width=w,length=l,depth=d,minimum=m,state="CRIADO",
    start={x=x,y=y,z=z},
  }
  t.nextId=t.nextId+1
  t.jobs[#t.jobs+1]=j
  saveJobs(t)
  print("Job criado: #"..j.id.." "..j.name.." inicio="..x..","..y..","..z)
end

local function createTransport(t,name,source,destination)
  if not name or name=="" or name:find("%s") then error("Nome do job deve ser uma palavra.",0) end
  if findJob(t,name) then error("Ja existe job com esse nome.",0) end
  if not source or source=="" or not destination or destination=="" then
    error("Uso: dev jobs create transport <nome> <origem> <destino>",0)
  end
  if source==destination then error("Origem e destino precisam ser diferentes.",0) end
  local j={
    id=t.nextId,type="transport",name=name,source=source,destination=destination,state="CRIADO",
  }
  t.nextId=t.nextId+1
  t.jobs[#t.jobs+1]=j
  saveJobs(t)
  print("Job transport criado: #"..j.id.." "..name.." "..source.." -> "..destination)
end

local function menu(t)
  while true do
    term.clear(); term.setCursorPos(1,1)
    print("ATM10 JOBS - Pocket")
    print("")
    listJobs(t)
    print("")
    print("[1] Descobrir turtles")
    print("[2] Criar job")
    print("[3] Atribuir turtle")
    print("[4] Iniciar job")
    print("[5] Pausar turtle")
    print("[6] Retomar turtle")
    print("[7] Mandar para base")
    print("[8] Cancelar")
    print("[Q] Sair")
    write("> ")
    local op=read()
    if op=="q" or op=="Q" then return
    elseif op=="1" then
      printTurtles(discover(3)); print("Enter..."); read()
    elseif op=="2" then
      write("Tipo [mine/transport]: "); local kind=read()
      if kind=="transport" then
        write("Nome: "); local name=read()
        write("Station origem: "); local source=read()
        write("Station destino: "); local destination=read()
        local ok,err=pcall(createTransport,t,name,source,destination)
        if not ok then printError(err); sleep(2) end
      else
        write("Nome: "); local name=read()
        write("Largura: "); local w=read()
        write("Comprimento: "); local l=read()
        write("Profundidade: "); local d=read()
        write("Inicio GPS X: "); local x=read()
        write("Inicio GPS Y: "); local y=read()
        write("Inicio GPS Z: "); local z=read()
        write("Min fuel [500]: "); local m=read(); if m=="" then m=500 end
        local ok,err=pcall(createJob,t,"mine",name,w,l,d,x,y,z,m)
        if not ok then printError(err); sleep(2) end
      end
    elseif op=="3" then
      write("Job nome/id: "); local key=read()
      local j=findJob(t,key)
      if not j then printError("Job nao encontrado."); sleep(2)
      else
        printTurtles(discover(2))
        write("ID turtle: "); local id=tonumber(read())
        if id then j.turtleId=id; j.state="ATRIBUIDO"; saveJobs(t) end
      end
    elseif op=="4" then
      write("Job nome/id: "); local j=findJob(t,read())
      if not j then printError("Job nao encontrado."); sleep(2)
      else local ok,err=pcall(startJob,t,j); if not ok then printError(err); sleep(2) end end
    elseif op=="5" or op=="6" or op=="7" or op=="8" then
      write("ID turtle: "); local id=read()
      local cmd=op=="5" and "pause" or op=="6" and "resume" or op=="7" and "home" or "cancel"
      local ok,err=pcall(sendMine,id,cmd); if not ok then printError(err) end
      sleep(1)
    end
  end
end

openWireless()
local t=loadJobs()
local cmd=args[1]
if not cmd then menu(t)
elseif cmd=="list" then listJobs(t)
elseif cmd=="discover" then printTurtles(discover(args[2] or 3))
elseif cmd=="create" then
  if args[2]=="transport" then
    createTransport(t,args[3],args[4],args[5])
  else
    createJob(t,args[2],args[3],args[4],args[5],args[6],args[7],args[8],args[9],args[10])
  end
elseif cmd=="assign" then
  local j=findJob(t,args[2]); local id=tonumber(args[3])
  if not j or not id then error("Uso: dev jobs assign <job> <turtleId>",0) end
  j.turtleId=id; j.state="ATRIBUIDO"; saveJobs(t)
  print("Job "..j.name.." atribuido a turtle "..id)
elseif cmd=="start" then
  local j=findJob(t,args[2]); if not j then error("Job nao encontrado.",0) end
  startJob(t,j)
elseif cmd=="pause" or cmd=="resume" or cmd=="home" or cmd=="cancel" then
  sendMine(args[2],cmd)
else
  error("Uso: dev jobs [list|discover|create|assign|start|pause|resume|home|cancel]",0)
end
