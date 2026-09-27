-- Run with Lua 5.2+ from the repository root: lua tests/mine_test.lua
-- Tests emulate CC APIs; an in-game smoke test is still required.
local source = MINE_SOURCE
if not source then
    local h = assert(io.open('dev/bin/mine.lua', 'r'))
    source = h:read('*a'); h:close()
end
local function encode(v)
    if type(v) ~= 'table' then
        return type(v) == 'string' and string.format('%q', v) or tostring(v)
    end
    local parts = {}
    for k, item in pairs(v) do parts[#parts+1] = '['..encode(k)..']='..encode(item) end
    return '{'..table.concat(parts, ',')..'}'
end
local function simulation(w, l, d, options)
    options = options or {}
    local m = {x=0,y=0,z=0,dir=0,fuel=0,selected=1,inv={},disk={},blocks={},
        digs=0,moves=0,departures=0,turns=0,waits=0,coal=options.coal or 5000,
        logs={},answers={'MINERAR'},crash=options.crash,full=options.full,
        saves=0,stopSave=options.stopSave,horizontal={}}
    local function key(x,y,z) return x..','..y..','..z end
    for y=1,d do for z=0,l-1 do for x=0,w-1 do
        if not options.empty or y > options.empty then m.blocks[key(x,-y,z)] = true end
    end end end
    local env = setmetatable({}, {__index=_G})
    local function target(kind)
        local x,y,z=m.x,m.y,m.z
        if kind=='up' then y=y+1 elseif kind=='down' then y=y-1
        elseif m.dir==0 then z=z+1 elseif m.dir==1 then x=x+1
        elseif m.dir==2 then z=z-1 else x=x-1 end
        return x,y,z
    end
    local function atChest() return m.x==0 and m.y==0 and m.z==0 and m.dir==2 end
    local function count(i) return m.inv[i or m.selected] and m.inv[i or m.selected].count or 0 end
    local function addItem(name)
        for i=1,16 do if not m.inv[i] then m.inv[i]={name=name,count=1}; return true end end
        error('lost item: inventory overflow')
    end
    local function move(kind)
        local x,y,z=target(kind)
        assert(x>=0 and x<w and z>=0 and z<l and y<=0 and y>=-d,'movement outside area')
        if m.blocks[key(x,y,z)] then return false,'block' end
        if kind=='forward' then m.horizontal[y]=(m.horizontal[y] or 0)+1 end
        assert(m.fuel > 0, 'out of fuel')
        if m.y==0 and y==-1 then
            m.departures=m.departures+1
            assert(m.fuel>=math.max(options.minimum or 1,2*(w+l+d-2)+32),'departed below minimum')
        end
        m.fuel=m.fuel-1; m.x,m.y,m.z=x,y,z; m.moves=m.moves+1
        if m.crash and m.moves==m.crash then error('simulated power loss after movement') end
        return true
    end
    local function dig(kind)
        local x,y,z=target(kind)
        local k=key(x,y,z)
        if m.bedrock==k then return false,'unbreakable' end
        if not m.blocks[k] then return false,'air' end
        assert(x>=0 and x<w and z>=0 and z<l and y<0 and y>=-d,'dig outside area')
        m.blocks[k]=nil; m.digs=m.digs+1; addItem('ore_'..m.digs)
        return true
    end
    local function detect(kind) local x,y,z=target(kind); return m.blocks[key(x,y,z)]~=nil end
    local function log(s) m.logs[#m.logs+1]=tostring(s) end
    env.print=log; env.printError=log; env.write=log
    env.read=function() return table.remove(m.answers,1) or '' end
    env.sleep=function()
        m.waits=m.waits+1
        if m.stopWaiting then error('stopped while waiting') end
        assert(m.waits<20,'wait loop never resolved')
        m.full=false
        m.coal=5000
        m.wrongFuel=nil
    end
    env.fs={
        exists=function(p) return m.disk[p]~=nil end,
        makeDir=function() end,
        open=function(p,mode)
            if mode=='r' then return {readAll=function() return m.disk[p] end,close=function() end} end
            return {write=function(s) m.disk[p]=s end,close=function()
                m.saves=m.saves+1
                if m.stopSave==m.saves then error('simulated interruption at checkpoint') end
            end}
        end
    }
    env.textutils={serialize=encode,unserialize=function(s)
        return assert(load('return '..s,'state','t',{}))()
    end}
    env.peripheral={wrap=function(side)
        if not options.peripheral or side~='front' or not atChest() or m.noChest then return nil end
        return {size=function() return 27 end,list=function()
            if m.coal==0 then return {} end
            return {[1]={name='minecraft:coal',count=m.coal}}
        end}
    end}
    env.turtle={
        inspect=function()
            if atChest() and not m.noChest then
                return true,{name=options.blockName or 'minecraft:chest',tags=options.tags or {}}
            end
            return false,'No block to inspect'
        end,
        select=function(i) m.selected=i; return true end,
        getItemCount=count,
        getItemDetail=function(i) return m.inv[i or m.selected] end,
        getFuelLevel=function() return m.fuel end,
        getFuelLimit=function() return 20000 end,
        turnLeft=function() m.dir=(m.dir+3)%4; m.turns=m.turns+1; return true end,
        turnRight=function() m.dir=(m.dir+1)%4; m.turns=m.turns+1; return true end,
        forward=function() return move('forward') end,
        up=function() return move('up') end,
        down=function() return move('down') end,
        detect=function() return detect('forward') end,
        detectUp=function() return detect('up') end,
        detectDown=function() return detect('down') end,
        dig=function() return dig('forward') end,
        digUp=function() return dig('up') end,
        digDown=function() return dig('down') end,
        drop=function()
            assert(atChest() and not m.noChest, 'dropped outside chest')
            if m.full then return false end
            if m.inv[m.selected] and m.inv[m.selected].name=='minecraft:coal' then
                m.coal=m.coal+m.inv[m.selected].count
            end
            m.inv[m.selected]=nil; return true
        end,
        suck=function(n)
            assert(atChest(), 'suck outside base')
            assert(not m.inv[m.selected], 'fuel slot occupied')
            if m.wrongFuel then m.inv[m.selected]={name='minecraft:stone',count=n}; return true end
            n=math.min(n,m.coal)
            if n==0 then return false end
            m.coal=m.coal-n; m.inv[m.selected]={name='minecraft:coal',count=n}; return true
        end,
        refuel=function(n)
            assert(m.inv[m.selected].name=='minecraft:coal','burned nonfuel')
            assert(m.inv[m.selected].count>n, 'consumed reserved last coal')
            m.inv[m.selected].count=m.inv[m.selected].count-n
            m.fuel=m.fuel+n*80; return true
        end,
    }
    m.execute=function(...)
        return pcall(assert(load(source,'mine.lua','t',env)),...)
    end
    m.start=function() return m.execute('start',tostring(w),tostring(l),tostring(d),tostring(options.minimum or 1)) end
    m.state=function()
        local a=m.disk['/dev/mine-state.a']; local b=m.disk['/dev/mine-state.b']
        a=a and env.textutils.unserialize(a); b=b and env.textutils.unserialize(b)
        return not a and b or not b and a or a.serial>b.serial and a or b
    end
    m.done=function()
        assert(m.state().mode=='done')
        assert(m.x==0 and m.y==0 and m.z==0 and m.dir==0,'did not return home')
        assert(next(m.inv)==nil,'did not unload')
        assert(next(m.blocks)==nil,'missed cells')
    end
    return m
end
local tests=0
local function test(name,fn) fn(); tests=tests+1; print('PASS '..name) end
for _,dims in ipairs({{1,1,1},{2,3,2},{3,4,3},{4,3,2},{8,8,3}}) do
    test('complete '..table.concat(dims,'x'),function()
        local m=simulation(table.unpack(dims))
        assert(m.start()); m.done()
        assert(m.digs==dims[1]*dims[2]*dims[3])
    end)
end
test('empty layers and low fuel return',function()
    local m=simulation(9,8,3,{empty=2})
    assert(m.start()); m.done(); assert(m.digs==72); assert(m.departures>3)
    assert(not m.horizontal[-1] and not m.horizontal[-2], 'traversed air layer')
end)
test('all air descends to configured limit and returns directly',function()
    local m=simulation(9,8,12,{empty=12})
    assert(m.start()); m.done()
    assert(m.moves==24 and m.digs==0 and next(m.horizontal)==nil)
end)
test('a hole in the first column intentionally skips isolated blocks',function()
    local m=simulation(3,3,2)
    m.blocks['0,-1,0']=nil
    assert(m.start())
    assert(m.state().mode=='done' and m.blocks['1,-1,0'])
    assert(not m.horizontal[-1] and m.digs==9)
end)
test('full inventory returns and resumes exact cell',function()
    local m=simulation(7,5,2,{minimum=5000})
    assert(m.start()); m.done(); assert(m.departures>=6)
end)
test('full chest waits and resumes',function()
    local m=simulation(2,2,1,{full=true})
    m.inv[1]={name='stone',count=64}
    assert(m.start()); m.done(); assert(m.waits>=1)
end)
test('low fuel waits at home until reserve is available',function()
    local m=simulation(2,2,1,{coal=1,minimum=500})
    assert(m.start()); m.done(); assert(m.waits>=1)
end)
test('unbreakable block stops without false progress and resumes',function()
    local m=simulation(3,3,2)
    m.bedrock='2,-1,0'
    local ok,err=m.start(); assert(not ok and err:find('Bloco nao pode'))
    assert(not m.state().pending and m.state().cursor==2)
    m.bedrock=nil; assert(m.execute('resume')); m.done()
end)
test('power loss refuses blind resume, home recovery works',function()
    local m=simulation(4,4,2,{crash=10})
    local ok=m.start(); assert(not ok and m.state().pending)
    local before=m.moves
    local resumed,err=m.execute('resume')
    assert(not resumed and err:find('posicao incerta') and m.moves==before)
    m.x,m.y,m.z,m.dir=0,0,0,0; m.crash=nil; m.answers={'ORIGEM'}
    assert(m.execute('recover-home')); assert(m.execute('resume')); m.done()
end)
test('missing chest never drops or leaves home',function()
    local m=simulation(2,2,1); m.noChest=true; m.inv[1]={name='stone',count=1}
    local ok,err=m.start(); assert(not ok and err:find('Bau nao reconhecido'))
    assert(m.moves==0 and m.inv[1]); m.noChest=false
    assert(m.execute('resume')); m.done()
end)
test('normal chest works without peripheral exposure',function()
    local m=simulation(3,3,2)
    assert(m.start()); m.done()
end)
test('non-inventory block is rejected without dropping items',function()
    local m=simulation(2,2,1,{blockName='minecraft:stone'})
    m.inv[1]={name='ore',count=1}
    local ok,err=m.start()
    assert(not ok and err:find('minecraft:stone') and m.inv[1] and m.moves==0)
end)
test('nonfuel from chest is returned and not consumed',function()
    local m=simulation(2,2,1); m.wrongFuel=true
    assert(m.start()); m.done(); assert(m.waits>=1)
end)
test('tagged mod chest and generic inventory remain supported',function()
    local tagged=simulation(2,2,1,{blockName='test:chest',tags={['c:chests']=true}})
    assert(tagged.start()); tagged.done()
    local generic=simulation(2,2,1,{blockName='test:inventory',peripheral=true})
    assert(generic.start()); generic.done()
end)
test('waiting interruption can resume',function()
    local m=simulation(2,2,1,{coal=1}); m.stopWaiting=true
    assert(not m.start()); assert(m.moves==0 and not m.state().pending)
    m.stopWaiting=false; assert(m.execute('resume')); m.done()
end)
test('invalid dimensions never move',function()
    local m=simulation(2,2,1)
    assert(not m.execute('start','0','2','1')); assert(m.moves==0)
    assert(not m.execute('start','2','2','1','999999')); assert(m.moves==0)
end)
test('resume or recover at EVERY saved checkpoint',function()
    local baseline=simulation(3,3,2)
    assert(baseline.start())
    for checkpoint=1,baseline.saves do
        local m=simulation(3,3,2,{stopSave=checkpoint})
        assert(not m.start())
        m.stopSave=nil
        if m.state().pending then
            m.x,m.y,m.z,m.dir=0,0,0,0
            m.answers={'ORIGEM'}
            assert(m.execute('recover-home'))
        end
        assert(m.execute('resume')); m.done()
    end
end)
test('resume during every checkpoint of descent through air',function()
    local baseline=simulation(3,3,4,{empty=2})
    assert(baseline.start())
    for checkpoint=1,baseline.saves do
        local m=simulation(3,3,4,{empty=2,stopSave=checkpoint})
        assert(not m.start())
        m.stopSave=nil
        if m.state().pending then
            m.x,m.y,m.z,m.dir=0,0,0,0
            m.answers={'ORIGEM'}
            assert(m.execute('recover-home'))
        end
        assert(m.execute('resume')); m.done()
        assert(not m.horizontal[-1] and not m.horizontal[-2])
    end
end)
print(tests..' mining tests passed')
