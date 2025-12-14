local isESX = false
local isQB = false

if GetResourceState('es_extended') == 'started' then
    isESX = true
    ESX = exports['es_extended']:getSharedObject()
elseif GetResourceState('qb-core') == 'started' then
    isQB = true
    QBCore = exports['qb-core']:GetCoreObject()
end

-- Track looted zombies to prevent multiple players from looting same zombie
local lootedZombies = {}

RegisterNetEvent('zombies:giveLoot', function(zombieEntityId)
    local src = source
    local xPlayer = nil

    if not Config.EnableZombieLoot then
        return
    end

    -- Prevent multiple players from looting the same zombie
    if zombieEntityId and lootedZombies[zombieEntityId] then
        return
    end

    -- Verify framework is correct (QBCore for this server)
    if Config.Framework == 'ESX' and isESX then
        xPlayer = ESX.GetPlayerFromId(src)
    elseif Config.Framework == 'QBCORE' and isQB then
        xPlayer = QBCore.Functions.GetPlayer(src)
    else
        -- Framework mismatch - log warning but don't error
        print(string.format("[Zombies] Warning: Framework mismatch. Config says '%s' but detected framework doesn't match.", Config.Framework))
        return
    end

    if xPlayer then
        local itemsGiven = false
        
        for _, lootData in ipairs(Config.ZombieLootItems) do
            local chance = math.random(100)
            if chance <= lootData.chance then
                local quantity = math.random(lootData.min, lootData.max)
                if quantity > 0 then
                    if Config.Framework == 'ESX' then
                        xPlayer.addInventoryItem(lootData.item, quantity)
                        itemsGiven = true
                    elseif Config.Framework == 'QBCORE' then
                        xPlayer.Functions.AddItem(lootData.item, quantity)
                        TriggerClientEvent('inventory:client:ItemBox', src, QBCore.Shared.Items[lootData.item], 'add')
                        itemsGiven = true
                    end
                end
            end
        end
        
        -- Mark zombie as looted if items were given
        if itemsGiven and zombieEntityId then
            lootedZombies[zombieEntityId] = true
            -- Clean up after 30 seconds to prevent memory leak
            SetTimeout(30000, function()
                lootedZombies[zombieEntityId] = nil
            end)
        end
    end
end)
