local args={...}
local LOG="/dev/watchdog.log"

local function showLog()
  if not fs.exists(LOG) then print("Nenhum evento do watchdog."); return end
  local h=fs.open(LOG,"r"); if not h then return end
  local lines={}
  while true do local s=h.readLine(); if not s then break end; lines[#lines+1]=s end
  h.close()
  local start=math.max(1,#lines-29)
  for i=start,#lines do print(lines[i]) end
end

if args[1]=="log" then showLog(); return end
print("Watchdog ATM10")
print("Monitor de frota e recuperacao segura.")
print("Use: dev watchdog log")
