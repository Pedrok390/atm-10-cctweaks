-- ATM10 DevKit startup v1
-- Return to CraftOS normally, without loops or a replacement shell.
local ok, err = pcall(function()
    if fs.exists("/dev/dev.lua") and not fs.isDir("/dev/dev.lua") then
        shell.setAlias("dev", "/dev/dev.lua")
        print("[DevKit] Pronto. Digite dev help.")
    else
        printError("[DevKit] Arquivos ausentes. Execute o instalador novamente.")
    end
end)
if not ok then printError("[DevKit] " .. tostring(err)) end

-- Preserve the previous startup behavior.
if fs.exists("/startup.devkit-backup.lua") then
    local ran, result = pcall(shell.execute, "/startup.devkit-backup.lua")
    if not ran or not result then printError("[DevKit] Falha no startup anterior.") end
end
