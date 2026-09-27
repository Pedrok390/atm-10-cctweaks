local args = {...}

local function listAll()
    local names = peripheral.getNames()

    print("=== PERIPHERAL INSPECTOR ===")
    print()

    if #names == 0 then
        print("Nenhum peripheral encontrado.")
        return
    end

    for i, name in ipairs(names) do
        local types = { peripheral.getType(name) }

        print("[" .. i .. "] " .. name)

        print("    Tipos:")
        for _, peripheralType in ipairs(types) do
            print("      - " .. peripheralType)
        end

        print()
    end
end

local function inspect(name)
    if not peripheral.isPresent(name) then
        print("Peripheral nao encontrado:")
        print(name)
        return
    end

    print("=== INSPECT ===")
    print()
    print("Nome:")
    print(name)
    print()

    print("Tipos:")

    local types = { peripheral.getType(name) }

    for _, peripheralType in ipairs(types) do
        print("  - " .. peripheralType)
    end

    print()
    print("Metodos:")

    local methods = peripheral.getMethods(name)

    if methods then
        table.sort(methods)

        for _, method in ipairs(methods) do
            print("  - " .. method)
        end
    end
end

if #args == 0 then
    listAll()
else
    inspect(args[1])
end
