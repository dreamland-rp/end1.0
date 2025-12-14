local zombies = {}
local zombieHealth = {} -- Table to store previous health of each zombie
local currentZombieCount = 0
local zombieBlips = {}

-- Multiplayer player cache system (optimized)
local playerCache = {} -- playerCache[playerId] = {ped = ped, coords = vector3, lastUpdate = time, isValid = bool}
local playerCacheLastUpdate = 0
local playerNoiseCache = {} -- playerNoiseCache[playerId] = {pos = vector3, time = time, radius = number}

-- Track looted zombies to prevent multiple players from looting same zombie
local lootedZombies = {}

local soundManager = exports['xsound']
local soundIdCounter = 0 -- Counter for unique sound IDs

local attackAnimations = {
    {dict = "anim@ingame@melee@unarmed@streamed_core_zombie", anim = "short_90_punch"},
    {dict = "anim@ingame@melee@unarmed@streamed_variations_zombie", anim = "heavy_punch_b_var_2"}
}

local VehicleAttackDistance = Config.VehicleAttackDistance
local VehicleEnterDistance = Config.VehiclePullOutDistance
local PushForce = Config.PushForce
local DistanceTarget = Config.DistanceTarget

function playZombieAttack(zombie)
    if not DoesEntityExist(zombie) then
        return
    end
    local attack = attackAnimations[math.random(#attackAnimations)]
    RequestAnimDict(attack.dict)
    while not HasAnimDictLoaded(attack.dict) do
        Wait(0)
    end
    if DoesEntityExist(zombie) then
        TaskPlayAnim(zombie, attack.dict, attack.anim, 8.0, -8.0, -1, 1, 0, false, false, false)
    end
end

function IsNight()
    local hour = GetClockHours()
    return (hour >= 20 or hour < 6)
end

function GetVisionDistance()
    if IsNight() then
        return Config.NightVisionDistance
    else
        return Config.DayVisionDistance
    end
end

-- Optimized player cache update function
function UpdatePlayerCache()
    local currentTime = GetGameTimer()
    local localPlayerPed = PlayerPedId()
    local localPlayerCoords = GetEntityCoords(localPlayerPed)
    
    -- Only update cache periodically to avoid costly GetActivePlayers calls
    if (currentTime - playerCacheLastUpdate) < Config.PlayerCacheUpdateInterval then
        -- Update cached player positions without full refresh
        for playerId, cacheData in pairs(playerCache) do
            if cacheData.isValid and DoesEntityExist(cacheData.ped) then
                local distance = #(localPlayerCoords - cacheData.coords)
                -- Only update positions for players within reasonable distance
                if distance < Config.PlayerCacheMaxDistance then
                    cacheData.coords = GetEntityCoords(cacheData.ped)
                    cacheData.lastUpdate = currentTime
                else
                    -- Mark as invalid if too far away
                    cacheData.isValid = false
                end
            else
                cacheData.isValid = false
            end
        end
        return
    end
    
    -- Full cache refresh
    playerCacheLastUpdate = currentTime
    local activePlayers = GetActivePlayers()
    
    -- Clear invalid entries
    for playerId, cacheData in pairs(playerCache) do
        if not cacheData.isValid or (currentTime - cacheData.lastUpdate) > (Config.PlayerCacheUpdateInterval * 3) then
            playerCache[playerId] = nil
        end
    end
    
    -- Update cache with active players
    for _, playerId in ipairs(activePlayers) do
        local playerPed = GetPlayerPed(playerId)
        if DoesEntityExist(playerPed) then
            local playerCoords = GetEntityCoords(playerPed)
            local distance = #(localPlayerCoords - playerCoords)
            
            -- Only cache players within max distance
            if distance < Config.PlayerCacheMaxDistance then
                if not playerCache[playerId] then
                    playerCache[playerId] = {}
                end
                playerCache[playerId].ped = playerPed
                playerCache[playerId].coords = playerCoords
                playerCache[playerId].lastUpdate = currentTime
                playerCache[playerId].isValid = true
            elseif playerCache[playerId] then
                -- Remove from cache if too far
                playerCache[playerId].isValid = false
            end
        end
    end
end

-- Get all valid nearby players from cache (optimized)
function GetNearbyPlayersFromCache(checkCoords, maxDistance)
    local nearbyPlayers = {}
    local currentTime = GetGameTimer()
    
    for playerId, cacheData in pairs(playerCache) do
        if cacheData.isValid and DoesEntityExist(cacheData.ped) then
            local distance = #(checkCoords - cacheData.coords)
            if distance <= maxDistance then
                table.insert(nearbyPlayers, {
                    id = playerId,
                    ped = cacheData.ped,
                    coords = cacheData.coords,
                    distance = distance
                })
            end
        end
    end
    
    return nearbyPlayers
end

-- Get closest player to a position (optimized)
function GetClosestPlayer(checkCoords, maxDistance)
    local closestPlayer = nil
    local closestDistance = maxDistance or Config.MaxPlayerDetectionDistance
    local currentTime = GetGameTimer()
    
    for playerId, cacheData in pairs(playerCache) do
        if cacheData.isValid and DoesEntityExist(cacheData.ped) then
            local distance = #(checkCoords - cacheData.coords)
            if distance < closestDistance then
                closestDistance = distance
                closestPlayer = {
                    id = playerId,
                    ped = cacheData.ped,
                    coords = cacheData.coords,
                    distance = distance
                }
            end
        end
    end
    
    return closestPlayer, closestDistance
end

-- Multiplayer noise system - track noise per player
function makeNoiseForPlayer(playerId, coords, radius)
    if not playerNoiseCache[playerId] then
        playerNoiseCache[playerId] = {}
    end
    playerNoiseCache[playerId].pos = coords
    playerNoiseCache[playerId].time = GetGameTimer()
    playerNoiseCache[playerId].radius = radius
end

-- Get most recent noise from any nearby player
function GetRecentNoiseFromPlayers(checkCoords, maxDistance)
    local bestNoise = nil
    local bestDistance = maxDistance or Config.MaxPlayerDetectionDistance
    local currentTime = GetGameTimer()
    
    for playerId, noiseData in pairs(playerNoiseCache) do
        if noiseData.pos and (currentTime - noiseData.time) < Config.NoiseMemoryTime then
            local distance = #(checkCoords - noiseData.pos)
            if distance < noiseData.radius and distance < bestDistance then
                bestDistance = distance
                bestNoise = {
                    pos = noiseData.pos,
                    radius = noiseData.radius,
                    distance = distance
                }
            end
        end
    end
    
    return bestNoise
end

-- Legacy noise functions for backward compatibility (now uses local player)
function makeNoise(coords, radius)
    local localPlayerId = PlayerId()
    makeNoiseForPlayer(localPlayerId, coords, radius)
end

function GetNoisePositionIfRecent()
    local localPlayerCoords = GetEntityCoords(PlayerPedId())
    local noise = GetRecentNoiseFromPlayers(localPlayerCoords, Config.MaxPlayerDetectionDistance)
    if noise then
        return noise.pos, noise.radius
    end
    return nil, 0
end

function canZombieSeePlayer(zombie, playerPed, distance)
    if not DoesEntityExist(zombie) or not DoesEntityExist(playerPed) then
        return false
    end
    if distance > GetVisionDistance() then
        return false
    end
    return HasEntityClearLosToEntity(zombie, playerPed, 17)
end

-- Find best target player for zombie (closest visible player, or closest if none visible)
function FindBestTargetPlayer(zombie, zombieCoords)
    if not DoesEntityExist(zombie) then
        return nil
    end
    
    local visionDistance = GetVisionDistance()
    local nearbyPlayers = GetNearbyPlayersFromCache(zombieCoords, Config.MaxPlayerDetectionDistance)
    
    if #nearbyPlayers == 0 then
        return nil
    end
    
    local bestTarget = nil
    local bestDistance = Config.MaxPlayerDetectionDistance
    local bestVisible = false
    
    -- First pass: find closest visible player
    for _, playerData in ipairs(nearbyPlayers) do
        if DoesEntityExist(playerData.ped) then
            local distance = #(zombieCoords - playerData.coords)
            if distance <= visionDistance then
                local canSee = canZombieSeePlayer(zombie, playerData.ped, distance)
                if canSee and (not bestVisible or distance < bestDistance) then
                    bestTarget = playerData
                    bestDistance = distance
                    bestVisible = true
                end
            end
        end
    end
    
    -- If no visible player found, use closest player (for hearing-based tracking)
    if not bestTarget then
        for _, playerData in ipairs(nearbyPlayers) do
            if DoesEntityExist(playerData.ped) and playerData.distance < bestDistance then
                bestTarget = playerData
                bestDistance = playerData.distance
            end
        end
    end
    
    return bestTarget
end

function damageVehicle(vehicle)
    if not DoesEntityExist(vehicle) then
        return
    end
    local currentEngineHealth = GetVehicleEngineHealth(vehicle)
    local newHealth = currentEngineHealth - Config.VehicleDamageOnAttack
    if newHealth < 0 then newHealth = 0 end
    if DoesEntityExist(vehicle) then
        SetVehicleEngineHealth(vehicle, newHealth)
        ApplyForceToEntity(vehicle, 1, 0.0, -PushForce, 0.2, 0.0, 0.0, 0.0, false, true, true, false, true, true)

        local xOffset = (math.random() - 0.5) * 0.5
        local yOffset = (math.random() - 0.5) * 0.5
        local zOffset = 0.0
        SetVehicleDamage(vehicle, xOffset, yOffset, zOffset, 50.0, 0.1, true)
    end
end

function pullPlayerOutOfVehicle(zombie, playerPed, vehicle, zombieType)
    ClearPedTasksImmediately(playerPed)
    TaskLeaveVehicle(playerPed, vehicle, 16)
    Wait(1000)
    if IsPedInAnyVehicle(playerPed, false) then
        ClearPedTasksImmediately(playerPed)
        TaskLeaveVehicle(playerPed, vehicle, 16)
    end
    playZombieAttack(zombie)
    ApplyDamageToPed(playerPed, zombieType.damage, false)
end

function searchArea(zombie, coords, duration)
    TaskGoToCoordAnyMeans(zombie, coords.x, coords.y, coords.z, 1.0, 0, 0, 786603, 0)
    local endTime = GetGameTimer() + duration
    while GetGameTimer() < endTime and DoesEntityExist(zombie) and not IsPedDeadOrDying(zombie, true) do
        Wait(500)
    end

    if DoesEntityExist(zombie) and not IsPedDeadOrDying(zombie, true) then
        local animDict = "anim@ingame@move_m@zombie@strafe"
        local animName = "idle"

        RequestAnimDict(animDict)
        while not HasAnimDictLoaded(animDict) do
            Wait(0)
        end
        TaskPlayAnim(zombie, animDict, animName, 8.0, -8.0, -1, 1, 0, false, false, false)

        Wait(5000)
        ClearPedTasks(zombie)
        TaskWanderStandard(zombie, 10.0, 10)
    end
end

function isInZone(coords, zoneCoords, radius)
    return #(coords - zoneCoords) <= radius
end

function playerInRedZone()
    local playerCoords = GetEntityCoords(PlayerPedId())
    for _, zone in ipairs(Config.RedZones) do
        if isInZone(playerCoords, zone.coords, zone.radius) then
            return true
        end
    end
    return false
end

function zombieInSafeZone(zombieCoords)
    for _, zone in ipairs(Config.SafeZones) do
        if isInZone(zombieCoords, zone.coords, zone.radius) then
            return true
        end
    end
    return false
end

-- Estado para saber si el zombie está corriendo o no
-- para no re-asignar tareas innecesariamente
local zombieStates = {} -- zombieStates[zombie] = { isRunning = false, originalClipset = "..."}

-- Nueva función: Ajustar velocidad del zombie y clipset según estado
-- Cuando el jugador esté sprintando y distancia > 2, el zombie corre (sin clipset) tras el jugador usando TaskGoToEntity a zombieType.speed
-- Cuando el jugador deja de sprintar o está a <= 2m, el zombie vuelve a su clipset original y velocidad normal
function updateZombieMovementStyle(zombie, zombieType, playerPed, distanceToPlayer)
    if not DoesEntityExist(zombie) or not DoesEntityExist(playerPed) then
        return
    end
    
    local playerSpeed = GetEntitySpeed(playerPed)
    local isPlayerSprinting = playerSpeed > 2.0 -- Threshold for "sprint"

    if not zombieStates[zombie] then
        -- Save initial state
        zombieStates[zombie] = {isRunning = false, originalClipset = nil}
    end

    if zombieStates[zombie].originalClipset == nil then
        -- Save original clipset (the one already set)
        if zombieType.clipsets and zombieType.clipsets[1] then
            zombieStates[zombie].originalClipset = zombieType.clipsets[1]
        end
    end

    if not DoesEntityExist(zombie) or not DoesEntityExist(playerPed) then
        return
    end

    if isPlayerSprinting and distanceToPlayer > 2.0 then
        -- Remove clipset and run
        if not zombieStates[zombie].isRunning then
            -- Change to run mode
            if DoesEntityExist(zombie) then
                ResetPedMovementClipset(zombie, 1.0)
                Wait(500)
                if DoesEntityExist(zombie) and DoesEntityExist(playerPed) then
                    -- Assign task with TaskGoToEntity with higher speed
                    TaskGoToEntity(zombie, playerPed, -1, 0.0, zombieType.speed, 1073741824, 0)
                    zombieStates[zombie].isRunning = true
                end
            end
        else
            -- Already running, make sure it keeps chasing
            if DoesEntityExist(zombie) and DoesEntityExist(playerPed) then
                TaskGoToEntity(zombie, playerPed, -1, 0.0, zombieType.speed, 1073741824, 0)
            end
        end
    else
        -- Return to normal clipset
        if zombieStates[zombie].isRunning then
            local clipset = zombieStates[zombie].originalClipset
            if clipset and DoesEntityExist(zombie) then
                RequestAnimSet(clipset)
                while not HasAnimSetLoaded(clipset) and DoesEntityExist(zombie) do
                    Wait(0)
                end
                if DoesEntityExist(zombie) and DoesEntityExist(playerPed) then
                    SetPedMovementClipset(zombie, clipset, 1.0)
                    Wait(500)
                    if DoesEntityExist(zombie) and DoesEntityExist(playerPed) then
                        TaskGoToEntity(zombie, playerPed, -1, 0.0, 1.0, 1073741824, 0)
                        zombieStates[zombie].isRunning = false
                    end
                end
            end
        else
            -- Already in normal mode, ensure it chases with normal speed
            if DoesEntityExist(zombie) and DoesEntityExist(playerPed) then
                TaskGoToEntity(zombie, playerPed, -1, 0.0, 1.0, 1073741824, 0)
            end
        end
    end
end

-- Function to create a single zombie at specific coordinates
function createZombieAtPosition(spawnX, spawnY, spawnZ)
    -- Encontrar la coordenada de suelo
    local foundGround, groundZ = GetGroundZFor_3dCoord(spawnX, spawnY, spawnZ, false)
    local tries = 0
    while (not foundGround) and (tries < 100) do
        spawnZ = spawnZ - 1.0
        foundGround, groundZ = GetGroundZFor_3dCoord(spawnX, spawnY, spawnZ, false)
        tries = tries + 1
        Wait(0)
    end
    
    if not foundGround then
        return nil
    end

    spawnZ = groundZ

    local zombieTypesKeys = {}
    for k,_ in pairs(Config.ZombieTypes) do
        table.insert(zombieTypesKeys, k)
    end
    local chosenTypeKey = zombieTypesKeys[math.random(#zombieTypesKeys)]
    local zombieType = Config.ZombieTypes[chosenTypeKey]

    local model = zombieType.models[math.random(#zombieType.models)]
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(0) end

    local zombie = CreatePed(4, model, spawnX, spawnY, spawnZ, 0.0, true, true)
    if not DoesEntityExist(zombie) then
        return nil
    end

    SetPedFleeAttributes(zombie, 0, false)
    SetBlockingOfNonTemporaryEvents(zombie, true)
    SetPedConfigFlag(zombie, 42, true)
    SetPedCombatAttributes(zombie, 46, true)
    DisablePedPainAudio(zombie, true)
    StopCurrentPlayingAmbientSpeech(zombie)
    StopPedSpeaking(zombie, true)

    TaskWanderStandard(zombie, 10.0, 10)
    SetPedAsEnemy(zombie, false)
    SetPedCombatAttributes(zombie, 46, false)
    SetPedFleeAttributes(zombie, 0, 0)
    SetPedCombatAbility(zombie, 0)
    SetPedCombatMovement(zombie, 0)
    SetPedCombatRange(zombie, 0)
    SetPedTargetLossResponse(zombie, 0)
    SetPedAlertness(zombie, 0)
    SetPedAccuracy(zombie, 0)

    local clipset = zombieType.clipsets[math.random(#zombieType.clipsets)]
    RequestAnimSet(clipset)
    while not HasAnimSetLoaded(clipset) do
        Wait(0)
    end
    SetPedMovementClipset(zombie, clipset, 1.0)

    table.insert(zombies, zombie)
    -- Safely increment count with check to prevent exceeding max
    -- Double-check count right before incrementing to handle race conditions
    if currentZombieCount < Config.MaxZombiesPerPlayer and DoesEntityExist(zombie) then
        currentZombieCount = currentZombieCount + 1
    end

    zombieHealth[zombie] = GetEntityHealth(zombie)

    -- Use unique sound ID to prevent conflicts
    soundIdCounter = soundIdCounter + 1
    local soundFile = 'nui://' .. GetCurrentResourceName() .. '/sounds/' .. zombieType.sound
    local soundId = "zombie_sound_" .. tostring(zombie) .. "_" .. tostring(soundIdCounter) .. "_" .. tostring(GetGameTimer())
    local zCoords = GetEntityCoords(zombie)
    soundManager:PlayUrlPos(soundId, soundFile, 0.5, zCoords, true)
    soundManager:Distance(soundId, 20.0)

    -- Start AI thread for this zombie
    Citizen.CreateThread(function()
        local zombieTypeForAI = zombieType -- Capture zombieType for AI thread
        local lastKnownPlayerPos = nil
        local searching = false

        while DoesEntityExist(zombie) do
            Wait(Config.ZombieAttackInterval)
            if IsPedDeadOrDying(zombie, true) then break end

            local zPos = GetEntityCoords(zombie)
            soundManager:Position(soundId, zPos)

            if zombieInSafeZone(zPos) then
                soundManager:Destroy(soundId)
                DeleteEntity(zombie)
                -- Safe removal from zombies table
                for i = #zombies, 1, -1 do
                    if zombies[i] == zombie then
                        table.remove(zombies, i)
                        -- Safely decrement count
                        if currentZombieCount > 0 then
                            currentZombieCount = currentZombieCount - 1
                        end
                        break
                    end
                end
                -- Clean up zombieStates memory leak
                zombieStates[zombie] = nil
                break
            end

            local zombieCoords = zPos
            
            -- Update player cache periodically
            UpdatePlayerCache()
            
            -- Find best target player (multiplayer support)
            local targetPlayer = FindBestTargetPlayer(zombie, zombieCoords)
            
            local currentHealth = GetEntityHealth(zombie) or 0
            if DoesEntityExist(zombie) and currentHealth < (zombieHealth[zombie] or 0) then
                zombieHealth[zombie] = currentHealth
                -- Make noise for all nearby players
                local nearbyPlayers = GetNearbyPlayersFromCache(zombieCoords, Config.AttackRadius)
                for _, playerData in ipairs(nearbyPlayers) do
                    makeNoiseForPlayer(playerData.id, zPos, Config.AttackRadius)
                end
            else
                if DoesEntityExist(zombie) then
                    zombieHealth[zombie] = currentHealth
                end
            end
            
            -- Check for noise from any player
            local noiseData = GetRecentNoiseFromPlayers(zombieCoords, Config.MaxPlayerDetectionDistance)
            local hearPlayer = false
            local noisePos = nil
            local noiseRadius = 0
            if noiseData then
                hearPlayer = true
                noisePos = noiseData.pos
                noiseRadius = noiseData.radius
            end

            -- If we have a target player, use it
            if targetPlayer and DoesEntityExist(targetPlayer.ped) then
                local playerPed = targetPlayer.ped
                local playerCoords = targetPlayer.coords
                local distance = targetPlayer.distance
                local seePlayer = canZombieSeePlayer(zombie, playerPed, distance)
                
                if seePlayer then
                    lastKnownPlayerPos = playerCoords
                    
                    -- Update movement style based on target player sprint and distance
                    updateZombieMovementStyle(zombie, zombieTypeForAI, playerPed, distance)

                    if IsPedInAnyVehicle(playerPed, false) then
                    local vehicle = GetVehiclePedIsIn(playerPed, false)
                    local distToVehicle = #(zombieCoords - GetEntityCoords(vehicle))
                    
                    if distToVehicle < DistanceTarget then
                        -- Ya se reconfiguró el estilo arriba, aquí mantenemos la lógica igual
                        -- Podrías opcionalmente volver a llamar updateZombieMovementStyle aquí si lo deseas
                        
                        TaskGoToEntity(zombie, vehicle, -1, 0.0, 1.0, 1073741824, 0)

                        if distToVehicle < VehicleAttackDistance then
                            playZombieAttack(zombie)
                            damageVehicle(vehicle)
                        end
                        
                        if Config.ZombiesCanPullOut then
                            local rand = math.random(100)
                            if rand <= Config.PullOutChance and distToVehicle < VehicleEnterDistance then
                                SetPedCanBeDraggedOut(playerPed, true)
                                TaskEnterVehicle(zombie, vehicle, -1, -1, 2.0, 8, 0)
            
                                Citizen.Wait(2000)
                                -- Reset SetPedCanBeDraggedOut after use
                                SetPedCanBeDraggedOut(playerPed, false)
                                if not IsPedInAnyVehicle(playerPed, false) then
                                    playZombieAttack(zombie)
                                    ApplyDamageToPed(playerPed, zombieTypeForAI.damage, false)
                                else
                                    playZombieAttack(zombie)
                                    damageVehicle(vehicle)
                                end
                            else
                                if distToVehicle < VehicleAttackDistance then
                                    playZombieAttack(zombie)
                                    damageVehicle(vehicle)
                                    
                                    local rand = math.random(100)
                                    if rand <= zombieTypeForAI.ragdollChance then
                                        -- Improved race condition handling - check vehicle state once
                                        local wasInVehicle = IsPedInAnyVehicle(playerPed, false)
                                        if wasInVehicle then
                                            ClearPedTasksImmediately(playerPed)
                                            
                                            local vehCoords = GetEntityCoords(vehicle)
                                            local offsetPos = GetOffsetFromEntityInWorldCoords(vehicle, 2.0, 0.0, 0.0)
                                            SetEntityCoords(playerPed, offsetPos.x, offsetPos.y, offsetPos.z)
                                            
                                            Wait(500)
                                            
                                            -- Double-check after wait to prevent race condition
                                            if not IsPedInAnyVehicle(playerPed, false) then
                                                SetPedCanRagdoll(playerPed, true)
                                                SetPedToRagdoll(playerPed, 1000, 1000, 0, true, true, false)
                                            end
                                        else
                                            -- Not in vehicle, safe to ragdoll
                                            SetPedCanRagdoll(playerPed, true)
                                            SetPedToRagdoll(playerPed, 1000, 1000, 0, true, true, false)
                                        end
                                    end
                                end
                            end
                        else
                            if distToVehicle < VehicleAttackDistance then
                                playZombieAttack(zombie)
                                damageVehicle(vehicle)
                            end
                        end
                    end
                else
                    -- Jugador a pie, ataque normal
                    if distance <= 2.0 then
                        playZombieAttack(zombie)
                        ApplyDamageToPed(playerPed, zombieTypeForAI.damage, false)
                    
                        local rand = math.random(100)
                        if rand <= zombieTypeForAI.ragdollChance then
                            SetPedCanRagdoll(playerPed, true)
                            SetPedToRagdoll(playerPed, 1000, 1000, 0, true, true, false)
                        end

                        updateZombieMovementStyle(zombie, zombieTypeForAI, playerPed, distance)
                    end
                    end
                end
            elseif hearPlayer and noisePos then
                -- Heard noise from any player, investigate
                lastKnownPlayerPos = noisePos
                TaskGoToCoordAnyMeans(zombie, noisePos.x, noisePos.y, noisePos.z, 1.0, 0, 0, 786603, 0)
                -- Get closest player for movement style update
                local closestPlayer = GetClosestPlayer(zombieCoords, Config.MaxPlayerDetectionDistance)
                if closestPlayer and DoesEntityExist(closestPlayer.ped) then
                    updateZombieMovementStyle(zombie, zombieTypeForAI, closestPlayer.ped, closestPlayer.distance)
                end
            elseif lastKnownPlayerPos and not searching then
                -- Search last known position
                searching = true
                searchArea(zombie, lastKnownPlayerPos, Config.SearchTime)
                lastKnownPlayerPos = nil
                searching = false
                -- Get closest player for movement style update
                local closestPlayer = GetClosestPlayer(zombieCoords, Config.MaxPlayerDetectionDistance)
                if closestPlayer and DoesEntityExist(closestPlayer.ped) then
                    updateZombieMovementStyle(zombie, zombieTypeForAI, closestPlayer.ped, closestPlayer.distance)
                end
            else
                -- No target, get closest player for movement style update
                local closestPlayer = GetClosestPlayer(zombieCoords, Config.MaxPlayerDetectionDistance)
                if closestPlayer and DoesEntityExist(closestPlayer.ped) then
                    updateZombieMovementStyle(zombie, zombieTypeForAI, closestPlayer.ped, closestPlayer.distance)
                end
            end

            if Config.ShowZombieBlips then
                -- Show blip if any player is nearby
                local closestPlayer = GetClosestPlayer(zombieCoords, Config.ZombieBlipRadius)
                local distToPlayer = closestPlayer and closestPlayer.distance or Config.ZombieBlipRadius + 1
                if distToPlayer <= Config.ZombieBlipRadius then
                    if not zombieBlips[zombie] then
                        local blip = AddBlipForEntity(zombie)
                        SetBlipSprite(blip, Config.ZombieBlip.Sprite)
                        SetBlipColour(blip, Config.ZombieBlip.Colour)
                        SetBlipScale(blip, Config.ZombieBlip.Scale)
                        SetBlipAsShortRange(blip, false)
            
                        BeginTextCommandSetBlipName("STRING")
                        AddTextComponentString(Config.ZombieBlip.Name)
                        EndTextCommandSetBlipName(blip)
            
                        zombieBlips[zombie] = blip
                    end
                else
                    if zombieBlips[zombie] then
                        RemoveBlip(zombieBlips[zombie])
                        zombieBlips[zombie] = nil
                    end
                end
            end            
        end
        
        if zombieBlips[zombie] then
            RemoveBlip(zombieBlips[zombie])
            zombieBlips[zombie] = nil
        end

        soundManager:Destroy(soundId)
        zombieHealth[zombie] = nil
        -- Clean up zombieStates to prevent memory leak
        zombieStates[zombie] = nil
    end)
    
    return zombie
end

-- Main spawn function that handles batch spawning and horde mode
function spawnZombie()
    -- Update player cache before spawning
    UpdatePlayerCache()
    
    if not playerInRedZone() then
        return
    end

    if currentZombieCount >= Config.MaxZombiesPerPlayer then
        return
    end

    -- Use local player for spawning (each client spawns around themselves)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    
    -- Calculate how many zombies to spawn
    local zombiesToSpawn = Config.ZombiesPerSpawn
    -- Get current count once to avoid race conditions
    local currentCount = currentZombieCount
    
    -- Prevent division by zero
    if Config.MaxZombiesPerPlayer > 0 then
        local zombieCountPercent = currentCount / Config.MaxZombiesPerPlayer
        
        -- Horde mode: spawn more zombies when count is low
        if zombieCountPercent <= Config.HordeSpawnThreshold then
            zombiesToSpawn = math.floor(Config.ZombiesPerSpawn * Config.HordeSpawnMultiplier)
        end
    end
    
    -- Don't exceed max - recalculate with current count
    currentCount = currentZombieCount
    local availableSlots = Config.MaxZombiesPerPlayer - currentCount
    zombiesToSpawn = math.min(zombiesToSpawn, availableSlots)
    
    if zombiesToSpawn <= 0 then
        return
    end

    -- Spawn zombies in batch
    local spawnAttempts = 0
    local spawned = 0
    
    -- Re-check count in loop condition to prevent race conditions
    while spawned < zombiesToSpawn and spawnAttempts < Config.MaxSpawnAttempts do
        -- Check count before each spawn attempt
        if currentZombieCount >= Config.MaxZombiesPerPlayer then
            break
        end
        spawnAttempts = spawnAttempts + 1
        
        -- Random spawn position around player
        local angle = math.random() * 2 * math.pi
        local distance = math.random(Config.SpawnRadius * 0.3, Config.SpawnRadius)
        local spawnX = playerCoords.x + math.cos(angle) * distance
        local spawnY = playerCoords.y + math.sin(angle) * distance
        local spawnZ = playerCoords.z + 50.0
        
        local zombie = createZombieAtPosition(spawnX, spawnY, spawnZ)
        if zombie then
            spawned = spawned + 1
        end
        
        -- Small delay between spawns to prevent blocking
        Wait(50)
    end
end

Citizen.CreateThread(function()
    while true do
        Wait(Config.SpawnInterval)
        spawnZombie()
    end
end)

Citizen.CreateThread(function()
    while true do
        Wait(1000)
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)

        -- Safe iteration: iterate backwards to safely remove items
        for i = #zombies, 1, -1 do
            local zombie = zombies[i]
            if DoesEntityExist(zombie) and GetEntityHealth(zombie) <= 0 then
                -- Zombie muerto encontrado
                local deadZombie = zombie
                
                -- Mark as being processed to prevent duplicate loot threads
                if not lootedZombies[deadZombie] then
                    lootedZombies[deadZombie] = true

                    -- Iniciar un hilo separado para manejar este zombie muerto
                    Citizen.CreateThread(function()
                        local deathTime = GetGameTimer()
                        local looted = false
                        local lastLootTime = 0
                        local lootCooldown = 2000 -- 2 second cooldown between loot attempts

                        while DoesEntityExist(deadZombie) and (GetGameTimer() - deathTime) < Config.DespawnTime do
                            Wait(0)
                            local playerPed = PlayerPedId()
                            local playerCoords = GetEntityCoords(playerPed)
                            local zCoords = GetEntityCoords(deadZombie)
                            local distance = #(playerCoords - zCoords)

                            if Config.EnableZombieLoot and distance < Config.LootDistance and not looted then
                                DrawMarker(20, zCoords.x, zCoords.y, zCoords.z+1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.3, 0.3, 0, 255, 0, 150, false, true, 2, false, nil, nil, false)
                                
                                -- Cooldown check to prevent spam clicking
                                if IsControlJustReleased(0, Config.LootKey) and (GetGameTimer() - lastLootTime) >= lootCooldown then
                                    lastLootTime = GetGameTimer()
                                    -- Send zombie entity ID to server for validation
                                    TriggerServerEvent('zombies:giveLoot', deadZombie)
                                    looted = true
                                    break
                                end
                            end
                        end

                        -- Después de lootear o cumplirse el tiempo
                        if DoesEntityExist(deadZombie) then
                            DeleteEntity(deadZombie)
                        end
                        -- Clean up loot tracking
                        lootedZombies[deadZombie] = nil
                    end)
                end

                -- Remover este zombie de la lista inmediatamente (safe because we iterate backwards)
                table.remove(zombies, i)

                if zombieBlips[zombie] then
                    RemoveBlip(zombieBlips[zombie])
                    zombieBlips[zombie] = nil
                end

                zombieHealth[zombie] = nil
                -- Clean up zombieStates to prevent memory leak
                zombieStates[zombie] = nil
                -- Safely decrement count
                if currentZombieCount > 0 then
                    currentZombieCount = currentZombieCount - 1
                end
            end
        end
    end
end)

-- Player cache update thread (optimized - updates periodically)
Citizen.CreateThread(function()
    while true do
        Wait(Config.PlayerCacheUpdateInterval)
        UpdatePlayerCache()
    end
end)

-- Multiplayer noise detection thread - tracks noise from all cached players
Citizen.CreateThread(function()
    local localPlayerPed = PlayerPedId()
    local localPlayerId = PlayerId()
    local lastVehicleSpeed = {}
    
    while true do
        Wait(1000)
        
        -- Update player cache
        UpdatePlayerCache()
        
        -- Track noise for all cached players (including local player)
        for playerId, cacheData in pairs(playerCache) do
            if cacheData.isValid and DoesEntityExist(cacheData.ped) then
                local playerPed = cacheData.ped
                local coords = cacheData.coords
                local isInVehicle = IsPedInAnyVehicle(playerPed, false)
                local speed = 0.0
                
                -- Initialize last speed for this player if needed
                if not lastVehicleSpeed[playerId] then
                    lastVehicleSpeed[playerId] = 0.0
                end

                if isInVehicle then
                    local vehicle = GetVehiclePedIsIn(playerPed, false)
                    if DoesEntityExist(vehicle) then
                        speed = GetEntitySpeed(vehicle)
                    end
                else
                    speed = GetEntitySpeed(playerPed)
                end

                -- Footstep noise
                if not isInVehicle then
                    if speed > 2.0 and not GetPedStealthMovement(playerPed) then
                        makeNoiseForPlayer(playerId, coords, Config.FootstepsNoiseRadius)
                    end
                end

                -- Vehicle high speed noise
                if isInVehicle and speed > Config.VehicleSpeedThreshold then
                    makeNoiseForPlayer(playerId, coords, Config.VehicleHighSpeedNoise)
                end

                -- Collision detection
                if isInVehicle then
                    local speedDrop = lastVehicleSpeed[playerId] - speed
                    if speedDrop > Config.CollisionSpeedDrop then
                        makeNoiseForPlayer(playerId, coords, Config.CollisionNoiseRadius)
                    end
                    lastVehicleSpeed[playerId] = speed
                else
                    lastVehicleSpeed[playerId] = 0.0
                end

                -- Horn noise
                if isInVehicle and IsControlPressed(0, 86) then
                    makeNoiseForPlayer(playerId, coords, Config.ClaxonNoiseRadius)
                end
            end
        end
        
        -- Clean up old noise cache entries
        local currentTime = GetGameTimer()
        for playerId, noiseData in pairs(playerNoiseCache) do
            if noiseData.time and (currentTime - noiseData.time) > Config.NoiseMemoryTime then
                playerNoiseCache[playerId] = nil
            end
        end
    end
end)

Citizen.CreateThread(function()
    if Config.ShowRedZoneBlips then
        for _, zone in ipairs(Config.RedZones) do
            local radiusBlip = AddBlipForRadius(zone.coords, zone.radius)
            SetBlipColour(radiusBlip, Config.RedZoneBlip.Colour)
            SetBlipAlpha(radiusBlip, 128)
            
            local blipMarker = AddBlipForCoord(zone.coords)
            SetBlipSprite(blipMarker, Config.RedZoneBlip.Sprite)
            SetBlipColour(blipMarker, Config.RedZoneBlip.Colour)
            SetBlipScale(blipMarker, Config.RedZoneBlip.Scale)
            SetBlipAsShortRange(blipMarker, true)
            
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentString(Config.RedZoneBlip.Name)
            EndTextCommandSetBlipName(blipMarker)
        end
    end

    if Config.ShowSafeZoneBlips then
        for _, zone in ipairs(Config.SafeZones) do
            local radiusBlip = AddBlipForRadius(zone.coords, zone.radius)
            SetBlipColour(radiusBlip, Config.SafeZoneBlip.Colour)
            SetBlipAlpha(radiusBlip, 128)

            local blipMarker = AddBlipForCoord(zone.coords)
            SetBlipSprite(blipMarker, Config.SafeZoneBlip.Sprite)
            SetBlipColour(blipMarker, Config.SafeZoneBlip.Colour)
            SetBlipScale(blipMarker, Config.SafeZoneBlip.Scale)
            SetBlipAsShortRange(blipMarker, true)
            
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentString(Config.SafeZoneBlip.Name)
            EndTextCommandSetBlipName(blipMarker)
        end
    end
end)