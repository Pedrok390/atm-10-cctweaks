local args = { ... }
if #args > 1 then error("Uso: dev inspect [nome]", 0) end
local lines = {}
local function add(line) lines[#lines + 1] = line end
local function types(name)
    local values = { peripheral.getType(name) }
    return #values > 0 and table.concat(values, ", ") or "desconectado"
end

if not args[1] then
    local names = peripheral.getNames()
    table.sort(names)
    add("=== Peripherals ===")
    if #names == 0 then add("Nenhum peripheral encontrado.") end
    for _, name in ipairs(names) do add(name .. " (" .. types(name) .. ")") end
    add("Detalhes: dev inspect <nome>")
else
    local name = args[1]
    if not peripheral.isPresent(name) then error("Peripheral nao encontrado: " .. name, 0) end
    add("Nome: " .. name)
    add("Tipos: " .. types(name))
    local methods = peripheral.getMethods(name)
    if not methods then error("Peripheral desconectado: " .. name, 0) end
    table.sort(methods)
    add("Metodos (" .. #methods .. "):")
    for _, method in ipairs(methods) do add("  " .. method) end
    if #methods == 0 then add("  Nenhum metodo exposto.") end
end
textutils.pagedPrint(table.concat(lines, "\n"))
