local args={...}
local JOBS="/dev/jobs"
local STATIONS="/dev/stations"

local function load(path,key)
  if not fs.exists(path) then return key and {} or nil end
  local h=fs.open(path,"r"); if not h then return key and {} or nil end
  local raw=h.readAll(); h.close()
  local ok,t=pcall(textutils.unserialize,raw or "")
  if not ok or type(t)~="table" then return key and {} or nil end
  return key and (type(t[key])=="table" and t[key] or {}) or t
end

local function chunk(n) return math.floor(tonumber(n)/16) end
local function key(cx,cz) return cx..","..cz end
local function add(set,cx,cz,label)
  local k=key(cx,cz)
  local e=set[k] or {x=cx,z=cz,labels={}}
  if label then e.labels[#e.labels+1]=label end
  set[k]=e
end

local function rect(set,x1,z1,x2,z2,label)
  local a,b=chunk(math.min(x1,x2)),chunk(math.max(x1,x2))
  local c,d=chunk(math.min(z1,z2)),chunk(math.max(z1,z2))
  for cx=a,b do for cz=c,d do add(set,cx,cz,label) end end
end

local function stationChunks(set)
  local stations=load(STATIONS,"stations")
  for name,s in pairs(stations) do
    if tonumber(s.x) and tonumber(s.z) then add(set,chunk(s.x),chunk(s.z),"station:"..name) end
  end
end

local function jobChunks(set,j)
  local kind=j.type or "mine"
  if kind=="mine" and type(j.start)=="table" then
    local x,z=tonumber(j.start.x),tonumber(j.start.z)
    local w,l=tonumber(j.width),tonumber(j.length)
    if x and z and w and l then
      -- Orientation is not stored in jobs yet. Show conservative square covering
      -- both possible horizontal quarry orientations around the GPS start.
      rect(set,x-(w-1),z-(l-1),x+(w-1),z+(l-1),"mine:"..tostring(j.name))
    end
  elseif kind=="transport" then
    local stations=load(STATIONS,"stations")
    local a,b=stations[j.source],stations[j.destination]
    if a and tonumber(a.x) and tonumber(a.z) then add(set,chunk(a.x),chunk(a.z),"transport:"..j.name..":origem") end
    if b and tonumber(b.x) and tonumber(b.z) then add(set,chunk(b.x),chunk(b.z),"transport:"..j.name..":destino") end
  end
end

local function sorted(set)
  local out={}
  for _,v in pairs(set) do out[#out+1]=v end
  table.sort(out,function(a,b) return a.x==b.x and a.z<b.z or a.x<b.x end)
  return out
end

local function printSet(set,title)
  local list=sorted(set)
  print(title.." ("..#list.." chunks)")
  for _,c in ipairs(list) do
    print(string.format("  %d %d  %s",c.x,c.z,table.concat(c.labels,", ")))
  end
end

local data=load(JOBS) or {jobs={}}
local cmd=args[1] or "active"
local set={}

if cmd=="stations" then
  stationChunks(set)
  printSet(set,"Chunks das stations")
elseif cmd=="job" then
  local wanted=tostring(args[2] or "")
  local found
  for _,j in ipairs(data.jobs or {}) do
    if tostring(j.id)==wanted or j.name==wanted then found=j; break end
  end
  if not found then error("Job nao encontrado.",0) end
  jobChunks(set,found)
  printSet(set,"Planejamento do job "..found.name)
  if (found.type or "mine")=="mine" then
    print("OBS: area conservadora; orientacao da quarry ainda nao fica salva no job.")
  elseif found.type=="transport" then
    print("OBS: mostra pontas. A rota pode atravessar chunks adicionais.")
  end
else
  stationChunks(set)
  for _,j in ipairs(data.jobs or {}) do
    if j.state=="FILA" or j.state=="DESPACHANDO" or j.state=="INICIANDO"
      or j.state=="MINERANDO" or j.state=="INDO_ORIGEM" or j.state=="INDO_DESTINO"
      or j.state=="PAUSADO" then
      jobChunks(set,j)
    end
  end
  printSet(set,"Chunks recomendados: stations + jobs ativos/fila")
  print("FTB Chunks: claim + force-load manualmente estes chunks.")
end
