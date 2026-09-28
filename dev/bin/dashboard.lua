local PROTOCOL="atm10:mine:telemetry"
local COMMAND="atm10:mine:command"
local mon=peripheral.find("monitor")
if not mon then error("Conecte um Advanced Monitor.",0) end
local modem
for _,n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n)=="modem" then
    local p=peripheral.wrap(n)
    if p and p.isWireless and p.isWireless() then modem=n break end
  end
end
if not modem then error("Conecte um wireless modem.",0) end
if not rednet.isOpen(modem) then rednet.open(modem) end
mon.setTextScale(0.5)
mon.setCursorBlink(false)

local data,selected={},nil
local buttons={}
local notice=""
local modes={dock="BASE",travel="INDO",mine="MINERANDO",home="VOLTANDO",done="CONCLUIDO"}

local function at(x,y,s,c,b)
  mon.setCursorPos(x,y)
  mon.setTextColor(c or colors.white)
  mon.setBackgroundColor(b or colors.black)
  mon.write(tostring(s))
end

local function clearLine(y,b)
  local w=mon.getSize()
  mon.setCursorPos(1,y)
  mon.setBackgroundColor(b or colors.black)
  mon.write(string.rep(" ",w))
end

local function ids()
  local r={}
  for id in pairs(data) do r[#r+1]=id end
  table.sort(r,function(a,b) return tostring(data[a].label)<tostring(data[b].label) end)
  return r
end

local function bar(x,y,w,v,max)
  v,max=tonumber(v) or 0,tonumber(max) or 0
  local n=max>0 and math.floor(math.max(0,math.min(1,v/max))*w) or 0
  at(x,y,string.rep(" ",n),colors.white,n>0 and colors.green or colors.gray)
  if n<w then at(x+n,y,string.rep(" ",w-n),colors.white,colors.gray) end
end

local function button(name,x,y,w,label,bg)
  at(x,y,string.rep(" ",w),colors.white,bg)
  local tx=x+math.max(0,math.floor((w-#label)/2))
  at(tx,y,label,colors.white,bg)
  buttons[name]={x1=x,x2=x+w-1,y=y}
end

local function sendCommand(cmd)
  if not selected then return end
  local ok=rednet.send(selected,{type="mine_command",target=selected,command=cmd},COMMAND)
  notice=(ok and "COMANDO ENVIADO: " or "FALHA AO ENVIAR: ")..string.upper(cmd)
end

local function draw()
  buttons={}
  local w,h=mon.getSize()
  mon.setBackgroundColor(colors.black) mon.clear()
  clearLine(1,colors.blue)
  at(2,1,"ATM10 TURTLES",colors.white,colors.blue)

  local list=ids()
  if not selected or not data[selected] then selected=list[1] end
  local left=math.min(21,math.floor(w*0.32))
  for y=2,h do
    at(1,y,string.rep(" ",left),colors.white,colors.gray)
  end
  at(2,3,"TURTLES",colors.yellow,colors.gray)

  local row=5
  for _,id in ipairs(list) do
    if row>h-1 then break end
    local t=data[id]
    local on=os.clock()-(t.seen or 0)<20
    local bg=id==selected and colors.lightGray or colors.gray
    at(2,row,(id==selected and "> " or "  ")..tostring(t.label or id),on and colors.white or colors.lightGray,bg)
    at(4,row+1,on and (modes[t.mode] or t.mode or "?") or "OFFLINE",on and colors.lime or colors.red,bg)
    row=row+3
  end

  local x=left+3
  if not selected then
    at(x,5,"Aguardando telemetria...",colors.white)
    return
  end

  local t=data[selected]
  at(x,3,tostring(t.label or selected),colors.yellow)
  at(x,5,"Modo:",colors.lightGray)
  local state=t.controlState or (t.paused and "PAUSADO") or (t.baseHold and "NA BASE") or (modes[t.mode] or t.mode or "?")
  local stateColor=(state=="RETORNANDO" or state=="CANCELANDO") and colors.orange
      or (state=="PAUSADO" and colors.yellow)
      or (state=="NA BASE" and colors.lime)
      or colors.white
  at(x+12,5,state,stateColor)
  at(x,7,"Fuel:",colors.lightGray) at(x+12,7,tostring(t.fuel).."/"..tostring(t.fuelLimit))
  if type(t.fuel)=="number" and type(t.fuelLimit)=="number" then bar(x,8,math.min(28,w-x-1),t.fuel,t.fuelLimit) end
  at(x,10,"Retorno:",colors.lightGray) at(x+12,10,tostring(t.returnAt or "?"))
  at(x,12,"Rel:",colors.lightGray) at(x+12,12,string.format("%s,%s,%s",t.x or "?",t.y or "?",t.z or "?"))
  at(x,14,"GPS:",colors.lightGray)
  if t.gps then
    at(x+12,14,string.format("%.1f,%.1f,%.1f",t.gps.x,t.gps.y,t.gps.z),colors.cyan)
  else
    at(x+12,14,"sem sinal",colors.orange)
  end
  at(x,16,"Base GPS:",colors.lightGray)
  if t.baseGps then
    at(x+12,16,string.format("%.1f,%.1f,%.1f",t.baseGps.x,t.baseGps.y,t.baseGps.z),colors.cyan)
  else
    at(x+12,16,"nao registrada",colors.orange)
  end
  at(x,18,"Dist GPS:",colors.lightGray)
  at(x+12,18,t.gpsDistance and string.format("%.1f",t.gpsDistance) or "?",colors.white)
  at(x,20,"Camada:",colors.lightGray) at(x+12,20,tostring(t.layer).."/"..tostring(t.depth))
  local cells=tonumber(t.cells) or 0
  local cur=tonumber(t.cursor) or 0
  local pct=cells>0 and math.floor(cur/cells*100) or 0
  at(x,22,"Progresso:",colors.lightGray) at(x+12,22,string.format("%d/%d %d%%",cur,cells,pct))
  bar(x,23,math.min(28,w-x-1),cur,math.max(cells,1))
  at(x,25,"Area:",colors.lightGray) at(x+12,25,string.format("%sx%sx%s",t.width or "?",t.length or "?",t.depth or "?"))
  at(x,27,"Slots:",colors.lightGray) at(x+12,27,tostring(t.freeSlots or "?").."/16")
  at(x,29,"Rota fuel:",colors.lightGray) at(x+12,29,tostring(t.routeState or "-"),colors.white)
  at(x,31,"Obstaculos:",colors.lightGray) at(x+12,31,tostring(t.routeKnown or 0),colors.white)
  at(x,33,"Recalculos:",colors.lightGray) at(x+12,33,tostring(t.routeReplans or 0),colors.white)
  at(x,35,"Restante:",colors.lightGray) at(x+12,35,tostring(t.routeRemaining or "-"),colors.white)
  local by=h-4
  button("pause",x,by,10,"PAUSAR",colors.red)
  button("resume",x+12,by,10,"RETOMAR",colors.green)
  button("home",x+24,by,10,"BASE",colors.orange)
  button("cancel",x,by+2,12,"CANCELAR",colors.red)
  if notice~="" then at(x+14,by+2,notice,colors.yellow) end
  at(x,h-1,"Toque na lista ou nos botoes.",colors.lightGray)
end

local function receiver()
  while true do
    local id,msg=rednet.receive(PROTOCOL,1)
    if id and type(msg)=="table" and msg.type=="mine_status" then
      msg.seen=os.clock() data[id]=msg
      if not selected then selected=id end
    end
    draw()
  end
end

local function touch()
  while true do
    local _,_,tx,y=os.pullEvent("monitor_touch")
    local handled=false
    for name,b in pairs(buttons) do
      if y==b.y and tx>=b.x1 and tx<=b.x2 then
        if name=="pause" then sendCommand("pause")
        elseif name=="resume" then sendCommand("resume")
        elseif name=="home" then sendCommand("home")
        elseif name=="cancel" then sendCommand("cancel") end
        handled=true
        break
      end
    end
    if not handled then
      local row=5
      for _,id in ipairs(ids()) do
        if y>=row and y<=row+1 then selected=id draw() break end
        row=row+3
      end
    end
  end
end

draw()
parallel.waitForAny(receiver,touch)
