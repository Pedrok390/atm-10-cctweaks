local args={...}
local JOB_PROTOCOL="atm10:job:command"
local STATUS_PROTOCOL="atm10:job:status"
local TELEMETRY_PROTOCOL="atm10:mine:telemetry"
local turtles={}
local selected=1

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
  put(1,h,"UP/DOWN seleciona | Q sai | R descobre")
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
          t.transportActive=msg.state~="CONCLUIDO" and msg.state~="SEM_CARGA" and msg.state~="ORIGEM_ESGOTADA"
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

local function inputLoop()
  while true do
    local _,key=os.pullEvent("key")
    local list=sorted()
    if key==keys.q then return
    elseif key==keys.up then selected=math.max(1,selected-1)
    elseif key==keys.down then selected=math.min(math.max(1,#list),selected+1)
    elseif key==keys.r then
      rednet.broadcast({type="job_command",command="discover"},JOB_PROTOCOL)
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
