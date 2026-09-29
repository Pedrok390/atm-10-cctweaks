local args={...}
local STATIONS="/dev/stations"
local STATUS_PROTOCOL="atm10:job:status"
local CONTROL_PROTOCOL="atm10:transport:command"
local CONTROL_ACK_PROTOCOL="atm10:transport:control:ack"
local MARGIN=32
local control={paused=false,cancel=false}

if not turtle then error("Este programa precisa ser executado em uma turtle.",0) end

local function fuel()
  local n=turtle.getFuelLevel()
  return n=="unlimited" and math.huge or n
end

local function coord(n)
  n=tonumber(n)
  return n and math.floor(n+0.5) or nil
end

local function loadStations()
  if not fs.exists(STATIONS) then return {} end
  local h=fs.open(STATIONS,"r")
  if not h then return {} end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" or type(t.stations)~="table" then return {} end
  return t.stations
end

local function wireless()
  if not rednet then return nil end
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
      local p=peripheral.wrap(name)
      if p and p.isWireless and p.isWireless() then
        if not rednet.isOpen(name) then rednet.open(name) end
        return name
      end
    end
  end
end

local function controlListener()
  wireless()
  while true do
    local sender,msg=rednet.receive(CONTROL_PROTOCOL)
    if type(msg)=="table" and (not msg.target or msg.target==os.getComputerID()) then
      local applied=false
      if msg.command=="pause" then control.paused=true; applied=true
      elseif msg.command=="resume" then control.paused=false; applied=true
      elseif msg.command=="cancel" then control.cancel=true; control.paused=false; applied=true
      end
      if applied and msg.requestId then
        rednet.send(sender,{
          type="transport_control_ack",id=os.getComputerID(),
          command=msg.command,requestId=msg.requestId,
        },CONTROL_ACK_PROTOCOL)
      end
    end
  end
end

local function report(state,jobId,jobName,extra)
  if not wireless() then return end
  local msg={
    type="transport_status",state=state,id=os.getComputerID(),
    jobId=jobId,jobName=jobName,
  }
  if type(extra)=="table" then for k,v in pairs(extra) do msg[k]=v end end
  rednet.broadcast(msg,STATUS_PROTOCOL)
end

local function gpsPoint(timeout)
  local x,y,z=gps.locate(timeout or 2,false)
  if not x then return nil end
  return {x=coord(x),y=coord(y),z=coord(z)}
end

local function key(p) return p.x..","..p.y..","..p.z end
local function manhattan(a,b)
  return math.abs(a.x-b.x)+math.abs(a.y-b.y)+math.abs(a.z-b.z)
end
local function copy(p) return {x=p.x,y=p.y,z=p.z} end

local function headingFromDelta(dx,dz)
  if dx==1 and dz==0 then return 1 end
  if dx==-1 and dz==0 then return 3 end
  if dx==0 and dz==1 then return 2 end
  if dx==0 and dz==-1 then return 0 end
end

local function turnTo(current,target)
  local d=(target-current)%4
  if d==1 then turtle.turnRight()
  elseif d==2 then turtle.turnRight(); turtle.turnRight()
  elseif d==3 then turtle.turnLeft() end
  return target
end

local function calibrate()
  local origin=gpsPoint(2)
  if not origin then return nil,"GPS sem sinal." end
  local turns=0
  for _=1,4 do
    if not turtle.detect() then
      if turtle.forward() then
        local now=gpsPoint(2)
        local back=turtle.back()
        if not now or not back then return nil,"Falha durante calibracao de direcao." end
        local moved=headingFromDelta(now.x-origin.x,now.z-origin.z)
        if not moved then return nil,"Nao foi possivel determinar orientacao." end
        local original=(moved-turns)%4
        for _=1,turns%4 do turtle.turnLeft() end
        return {pos=origin,heading=original,originalHeading=original}
      end
    end
    turtle.turnRight(); turns=turns+1
  end
  for _=1,turns%4 do turtle.turnLeft() end
  return nil,"Nenhum bloco livre ao redor para calibrar."
end

local NEIGHBORS={
  {x=0,y=1,z=0},{x=0,y=-1,z=0},
  {x=1,y=0,z=0},{x=-1,y=0,z=0},
  {x=0,y=0,z=1},{x=0,y=0,z=-1},
}

local function heuristic(p,goals)
  local best
  for _,g in ipairs(goals) do
    local d=manhattan(p,g)
    if not best or d<best then best=d end
  end
  return best or 0
end

local function reconstruct(came,nodes,k)
  local path={}
  while came[k] do
    table.insert(path,1,nodes[k])
    k=came[k]
  end
  return path
end

local function aStar(start,goals,blocked,margin)
  local goalByKey={}
  local minX,maxX,minY,maxY,minZ,maxZ=start.x,start.x,start.y,start.y,start.z,start.z
  for _,g in ipairs(goals) do
    goalByKey[key(g)]=g
    minX,maxX=math.min(minX,g.x),math.max(maxX,g.x)
    minY,maxY=math.min(minY,g.y),math.max(maxY,g.y)
    minZ,maxZ=math.min(minZ,g.z),math.max(maxZ,g.z)
  end
  minX,maxX=minX-margin,maxX+margin
  minY,maxY=minY-margin,maxY+margin
  minZ,maxZ=minZ-margin,maxZ+margin

  local sk=key(start)
  local open={sk}
  local inOpen={[sk]=true}
  local nodes={[sk]=copy(start)}
  local came={}
  local gScore={[sk]=0}
  local fScore={[sk]=heuristic(start,goals)}
  local expansions=0

  while #open>0 do
    expansions=expansions+1
    if expansions%64==0 then sleep(0) end
    local bi=1
    for i=2,#open do
      if (fScore[open[i]] or math.huge)<(fScore[open[bi]] or math.huge) then bi=i end
    end
    local ck=table.remove(open,bi)
    inOpen[ck]=nil
    local current=nodes[ck]
    if goalByKey[ck] then return reconstruct(came,nodes,ck),goalByKey[ck] end

    for _,d in ipairs(NEIGHBORS) do
      local n={x=current.x+d.x,y=current.y+d.y,z=current.z+d.z}
      if n.x>=minX and n.x<=maxX and n.y>=minY and n.y<=maxY and n.z>=minZ and n.z<=maxZ then
        local nk=key(n)
        if not blocked[nk] then
          local tentative=(gScore[ck] or math.huge)+1
          if tentative<(gScore[nk] or math.huge) then
            came[nk]=ck; nodes[nk]=n; gScore[nk]=tentative
            fScore[nk]=tentative+heuristic(n,goals)
            if not inOpen[nk] then open[#open+1]=nk; inOpen[nk]=true end
          end
        end
      end
    end
  end
  return nil
end

local function rawStep(nav,nextPos,blocked)
  local dx,dy,dz=nextPos.x-nav.pos.x,nextPos.y-nav.pos.y,nextPos.z-nav.pos.z
  local ok
  if dy==1 then
    if turtle.detectUp() then blocked[key(nextPos)]=true; return false end
    ok=turtle.up()
  elseif dy==-1 then
    if turtle.detectDown() then blocked[key(nextPos)]=true; return false end
    ok=turtle.down()
  else
    local h=headingFromDelta(dx,dz)
    if not h then error("Passo horizontal invalido.",0) end
    nav.heading=turnTo(nav.heading,h)
    if turtle.detect() then blocked[key(nextPos)]=true; return false end
    ok=turtle.forward()
  end
  if not ok then blocked[key(nextPos)]=true; return false end
  nav.pos=copy(nextPos)
  return true
end

local function navigate(nav,goals,blocked)
  local margins={4,8,16,32,64}
  for _=1,256 do
    local path,target
    for _,m in ipairs(margins) do
      path,target=aStar(nav.pos,goals,blocked,m)
      if path then break end
    end
    if not path then return false,"nenhuma rota encontrada" end
    local changed=false
    for _,p in ipairs(path) do
      if not rawStep(nav,p,blocked) then changed=true; break end
    end
    if not changed then return true,target end
  end
  return false,"limite de recalculos atingido"
end

local function standTargets(place)
  local x,y,z=coord(place.x),coord(place.y),coord(place.z)
  return {
    {x=x-1,y=y,z=z,face=1},
    {x=x+1,y=y,z=z,face=3},
    {x=x,y=y,z=z-1,face=2},
    {x=x,y=y,z=z+1,face=0},
  }
end

local function inventoryEmpty()
  for i=1,16 do if turtle.getItemCount(i)>0 then return false end end
  return true
end

local function cargoCount(filter)
  local n=0
  for i=1,16 do
    local d=turtle.getItemDetail(i)
    if d and (not filter or d.name==filter) then n=n+turtle.getItemCount(i) end
  end
  return n
end

local function pullCargo(filter,limit)
  local moved=0
  for i=1,16 do
    if limit and moved>=limit then break end
    turtle.select(i)
    local want=limit and math.max(0,limit-moved) or 64
    if want>0 then
      local before=turtle.getItemCount(i)
      local sucked=turtle.suck(math.min(64,want))
      if sucked then
        local detail=turtle.getItemDetail(i)
        local after=turtle.getItemCount(i)
        local gained=math.max(0,after-before)
        if filter and (not detail or detail.name~=filter) then
          if not turtle.drop() then
            error("Item fora do filtro foi puxado e nao consegui devolve-lo a origem.",0)
          end
        else
          moved=moved+gained
        end
      end
    end
  end
  turtle.select(1)
  return moved
end

local function dropCargo()
  for i=1,16 do
    if turtle.getItemCount(i)>0 then
      turtle.select(i)
      while turtle.getItemCount(i)>0 do
        local before=turtle.getItemCount(i)
        if not turtle.drop() then
          error("Station destino cheia ou recusou itens.",0)
        end
        if turtle.getItemCount(i)>=before then
          error("Nao foi possivel descarregar o slot "..i..".",0)
        end
      end
    end
  end
  turtle.select(1)
end

local sourceName,destName,jobId,jobName=args[1],args[2],args[3],args[4]
local itemFilter=args[5]~="" and args[5] or nil
local quantity=args[6]~="" and tonumber(args[6]) or nil
if quantity then quantity=math.floor(quantity) end
if not sourceName or not destName then
  error("Uso interno: transport.lua <origem> <destino> <jobId> <jobName>",0)
end
if not inventoryEmpty() then error("Inventario precisa estar vazio antes do transport.",0) end

local stations=loadStations()
local source,dest=stations[sourceName],stations[destName]
if not source then error("Station origem nao encontrada: "..sourceName,0) end
if not dest then error("Station destino nao encontrada: "..destName,0) end

local nav,err=calibrate()
if not nav then error(err,0) end
local blocked={}
blocked[key({x=coord(source.x),y=coord(source.y),z=coord(source.z)})]=true
blocked[key({x=coord(dest.x),y=coord(dest.y),z=coord(dest.z)})]=true

local sourceGoals,destGoals=standTargets(source),standTargets(dest)
local minSource=math.huge
for _,g in ipairs(sourceGoals) do minSource=math.min(minSource,manhattan(nav.pos,g)) end
local minDest=math.huge
for _,a in ipairs(sourceGoals) do
  for _,b in ipairs(destGoals) do minDest=math.min(minDest,manhattan(a,b)) end
end
local needed=minSource+minDest+MARGIN
if fuel()<needed then error("Combustivel insuficiente para transport. Precisa de pelo menos "..needed..".",0) end

local delivered=0
local trips=0

local function waitBeforePickup()
  while control.paused and not control.cancel do
    report("PAUSADO",jobId,jobName,{
      source=sourceName,destination=destName,item=itemFilter,
      delivered=delivered,target=quantity,trips=trips,
    })
    sleep(0.5)
  end
  return not control.cancel
end

local function runTransport()
while true do
  if not waitBeforePickup() then
    report("CANCELADO",jobId,jobName,{
      source=sourceName,destination=destName,item=itemFilter,
      delivered=delivered,target=quantity,trips=trips,
    })
    print("Transport cancelado com inventario vazio.")
    return
  end
  local remaining=quantity and (quantity-delivered) or nil
  if remaining and remaining<=0 then break end

  report("INDO_ORIGEM",jobId,jobName,{
    source=sourceName,destination=destName,item=itemFilter,
    delivered=delivered,target=quantity,trips=trips,
  })
  local ok,target=navigate(nav,sourceGoals,blocked)
  if not ok then error("Nao encontrei rota ate station origem: "..tostring(target),0) end
  nav.heading=turnTo(nav.heading,target.face)

  local count=pullCargo(itemFilter,remaining)
  if count==0 then
    local state=delivered>0 and "ORIGEM_ESGOTADA" or "SEM_CARGA"
    report(state,jobId,jobName,{
      source=sourceName,destination=destName,item=itemFilter,
      delivered=delivered,target=quantity,trips=trips,
    })
    print("Origem sem mais itens"..(itemFilter and (" do filtro "..itemFilter) or "")..
      ". Entregues: "..delivered..".")
    return
  end

  report("INDO_DESTINO",jobId,jobName,{
    items=count,source=sourceName,destination=destName,item=itemFilter,
    delivered=delivered,target=quantity,trips=trips,
  })
  ok,target=navigate(nav,destGoals,blocked)
  if not ok then error("Nao encontrei rota ate station destino: "..tostring(target),0) end
  nav.heading=turnTo(nav.heading,target.face)
  dropCargo()

  delivered=delivered+count
  trips=trips+1
  report("VIAGEM_CONCLUIDA",jobId,jobName,{
    items=count,source=sourceName,destination=destName,item=itemFilter,
    delivered=delivered,target=quantity,trips=trips,
  })

  if control.cancel then
    report("CANCELADO",jobId,jobName,{
      source=sourceName,destination=destName,item=itemFilter,
      delivered=delivered,target=quantity,trips=trips,
    })
    print("Transport cancelado apos entregar a carga atual.")
    return
  end
  if not itemFilter and not quantity then break end
end

report("CONCLUIDO",jobId,jobName,{
  source=sourceName,destination=destName,item=itemFilter,
  delivered=delivered,target=quantity,trips=trips,
})
print("Transport concluido: "..delivered.." itens em "..trips.." viagem(ns).")
end

parallel.waitForAny(runTransport,controlListener)
