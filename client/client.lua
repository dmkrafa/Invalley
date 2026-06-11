local QBCore = exports['qb-core']:GetCoreObject()

---------------------------------------------------------------------
-- DADOS PRINCIPAIS
---------------------------------------------------------------------

local PlayerData = {}
local ActiveUnits = {}
local Suspicion = 0
local WantedLevel = 0
local UnitBlips = {}
local CopRelationshipGroup = nil
local PlayerRelationshipGroup = `PLAYER`

---------------------------------------------------------------------
-- CONSTANTES DE ANIMAÇÃO
---------------------------------------------------------------------

local HANDCUFF_ANIMATION_DICT = "mp_arrest_paired"
local HANDCUFF_ANIMATION_NAME = "cop_p_s_pose_armed_1d"

local SURRENDER_ANIMS = {
    { dict = "random@arrests", anim = "idle_2_hands_up" },
    { dict = "random@arrests@busted", anim = "idle_a" },
    { dict = "mp_arresting", anim = "idle" }
}

local POLICE_DIALOGUE = {
    intro = "Pela ordem e paz da Infinity Valley!",
    arrest = "O(a) Senhor(a) está sendo preso!",
    crime_format = "Pelos crimes de %s durante %d minutos!",
    rights = "Você tem o direito de permanecer em silêncio..."
}

---------------------------------------------------------------------
-- DEBUG
---------------------------------------------------------------------

local function DebugPrint(...)
    if Config.Debug then
        print("^2[NPCPolice:Client]^7", ...)
    end
end

---------------------------------------------------------------------
-- FUNÇÕES AUXILIARES
---------------------------------------------------------------------

local function GetLocalPlayerPed()
    return PlayerPedId()
end

local function GetPlayerCoords()
    return GetEntityCoords(GetLocalPlayerPed())
end

local function GetDistance(coords1, coords2)
    return #(coords1 - coords2)
end

local function LoadModel(modelHash)
    local hash = GetHashKey(modelHash)
    if not IsModelInCdimage(hash) then return false end
    
    RequestModel(hash)
    local timeout = GetGameTimer() + 5000
    
    while not HasModelLoaded(hash) and GetGameTimer() < timeout do
        Wait(0)
    end
    
    return HasModelLoaded(hash)
end

local function LoadAnimation(dictName)
    RequestAnimDict(dictName)
    local timeout = GetGameTimer() + 5000
    
    while not HasAnimDictLoaded(dictName) and GetGameTimer() < timeout do
        Wait(0)
    end
    
    return HasAnimDictLoaded(dictName)
end

---------------------------------------------------------------------
-- CHECAGEM: JOGADOR RENDIDO?
---------------------------------------------------------------------

local function IsPlayerSurrendered(playerPed)
    if IsPedDeadOrDying(playerPed, 1) or IsPedFalling(playerPed) then 
        return false 
    end
    
    for _, surrender in ipairs(SURRENDER_ANIMS) do
        if IsEntityPlayingAnim(playerPed, surrender.dict, surrender.anim, 3) then
            return true
        end
    end
    
    if IsPedBeingArrested(playerPed) then
        return true
    end
    
    return false
end

---------------------------------------------------------------------
-- GERENCIAMENTO DE BLIPS
---------------------------------------------------------------------

local function UpdateUnitBlips()
    for unitId, unit in pairs(ActiveUnits) do
        if unit.vehicle and DoesEntityExist(unit.vehicle) then
            if not UnitBlips[unitId] then
                local blip = AddBlipForEntity(unit.vehicle)
                
                SetBlipSprite(blip, 56)
                SetBlipDisplay(blip, 4)
                SetBlipScale(blip, 0.85)
                SetBlipColour(blip, 38)
                SetBlipAsShortRange(blip, false)
                
                BeginTextCommandSetBlipName("STRING")
                AddTextComponentString("Viatura Policial")
                EndTextCommandSetBlipName(blip)
                
                SetBlipFlashes(blip, true)
                
                UnitBlips[unitId] = blip
            end
        else
            if UnitBlips[unitId] then
                local blip = UnitBlips[unitId]
                if blip and DoesBlipExist(blip) then
                    RemoveBlip(blip)
                end
                UnitBlips[unitId] = nil
            end
        end
    end
    
    for unitId, blip in pairs(UnitBlips) do
        if not ActiveUnits[unitId] and blip then
            if DoesBlipExist(blip) then
                RemoveBlip(blip)
            end
            UnitBlips[unitId] = nil
        end
    end
end

---------------------------------------------------------------------
-- SPAWN DE UNIDADE POLICIAL
---------------------------------------------------------------------

local function SpawnPoliceUnit(data)
    DebugPrint("Spawning police unit:", json.encode(data))
    
    local vehicleModel = data.vehicleModel
    local pedModel = data.pedModel
    local coords = data.coords
    local heading = data.heading
    local unitId = data.unitId
    local cops = data.cops or 1
    
    if not LoadModel(vehicleModel) or not LoadModel(pedModel) then
        DebugPrint("Failed to load models for unit:", unitId)
        return false
    end
    
    -- Inicializa grupo de relacionamento
    if not CopRelationshipGroup then
        local _, groupHash = AddRelationshipGroup("COP_AI_GROUP")
        CopRelationshipGroup = groupHash
        SetRelationshipBetweenGroups(5, CopRelationshipGroup, PlayerRelationshipGroup)
        SetRelationshipBetweenGroups(5, PlayerRelationshipGroup, CopRelationshipGroup)
    end
    
    local vehicle = CreateVehicle(GetHashKey(vehicleModel), coords.x, coords.y, coords.z, heading, true, false)
    
    if vehicle == 0 then
        DebugPrint("Failed to create vehicle for unit:", unitId)
        return false
    end
    
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleHasBeenOwnedByPlayer(vehicle, false)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    SetVehRadioStation(vehicle, "OFF")
    SetVehicleEngineHealth(vehicle, 1000.0)
    SetVehicleDirtLevel(vehicle, 0.0)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleSiren(vehicle, true)
    SetVehicleEngineOn(vehicle, true, true, false)
    
    local policeOfficers = {}
    
    for i = 1, cops do
        local seatIndex = (i == 1) and -1 or (i - 2)
        local isDriver = (seatIndex == -1)
        
        local ped = CreatePed(4, GetHashKey(pedModel), coords.x, coords.y, coords.z, 0.0, true, false)
        
        if ped and ped > 0 then
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetEntityAsMissionEntity(ped, true, true)
            SetPedRelationshipGroupHash(ped, CopRelationshipGroup)
            
            TaskWarpPedIntoVehicle(ped, vehicle, seatIndex)
            Wait(500)
            
            -- Configurações de combate
            SetPedCombatAttributes(ped, 46, true)
            SetPedCombatAttributes(ped, 5, true)
            SetPedCombatAttributes(ped, 2, false)
            SetPedCombatAbility(ped, 2)
            SetPedCombatRange(ped, 2)
            SetPedAccuracy(ped, Config.PoliceAI.AccuracyAggressive or 85)
            
            GiveWeaponToPed(ped, GetHashKey("WEAPON_PISTOL"), 255, false, true)
            SetCurrentPedWeapon(ped, GetHashKey("WEAPON_PISTOL"), true)
            
            table.insert(policeOfficers, {
                ped = ped,
                seatIndex = seatIndex,
                isDriver = isDriver,
                isOnFoot = false
            })
        end
    end
    
    local unit = {
        unitId = unitId,
        vehicle = vehicle,
        officers = policeOfficers,
        state = "awaiting_behavior",
        lastState = "awaiting_behavior",
        spawning = true,
        createdAt = GetGameTimer(),
        chaseStarted = false,
        playerDistance = 999.0,
        pursuitActive = false,
        arrestInProgress = false
    }
    
    ActiveUnits[unitId] = unit
    UpdateUnitBlips()
    DebugPrint("Police unit spawned successfully:", unitId)
    
    return true
end

---------------------------------------------------------------------
-- INICIAR PERSEGUIÇÃO EM VEÍCULO
---------------------------------------------------------------------

local function StartVehicleChase(unitId)
    local unit = ActiveUnits[unitId]
    if not unit or not unit.vehicle or not DoesEntityExist(unit.vehicle) then 
        return 
    end
    
    DebugPrint("Vehicle chase STARTED for unit:", unitId)
    
    unit.state = "vehicle_chase"
    unit.chaseStarted = true
    unit.pursuitActive = true
    
    local driverOfficer = nil
    for _, officer in pairs(unit.officers) do
        if officer.isDriver then 
            driverOfficer = officer 
            break 
        end
    end
    
    if driverOfficer and DoesEntityExist(driverOfficer.ped) then
        local driver = driverOfficer.ped
        
        -- Garante que está no banco do motorista
        if GetPedInVehicleSeat(unit.vehicle, -1) ~= driver then
            TaskWarpPedIntoVehicle(driver, unit.vehicle, -1)
            Wait(500)
        end
        
        ClearPedTasks(driver)
        Wait(200)
        
        -- Inicia perseguição agressiva
        TaskVehicleChase(driver, GetLocalPlayerPed())
        SetTaskVehicleChaseBehaviorFlag(driver, 1, true)
        SetTaskVehicleChaseIdealPursuitDistance(driver, 5.0)
        SetDriverAbility(driver, Config.PoliceAI.DriverAbility or 1.0)
        SetDriveTaskDrivingStyle(driver, 262144 + 2)
        
        DebugPrint("Driver assigned to chase for unit:", unitId)
    end
    
    -- Outros policiais preparam para combate
    for i = 2, #unit.officers do
        local officer = unit.officers[i]
        if officer.ped and DoesEntityExist(officer.ped) then
            local playerCoords = GetPlayerCoords()
            TaskStartScenarioInPlace(officer.ped, "WORLD_HUMAN_MOBILE_FILM_SHOCKING", 0, true)
            TaskTurnCharacterInDirection(officer.ped, playerCoords.x, playerCoords.y, 1000)
        end
    end
end

---------------------------------------------------------------------
-- TRANSIÇÃO PARA PERSEGUIÇÃO A PÉ
---------------------------------------------------------------------

local function TransitionToFootPursuit(unitId)
    local unit = ActiveUnits[unitId]
    if not unit or not unit.vehicle or not DoesEntityExist(unit.vehicle) then 
        return 
    end
    
    DebugPrint("Transitioning to FOOT PURSUIT for unit:", unitId)
    
    unit.state = "foot_pursuit"
    unit.pursuitActive = true
    
    -- Para o veículo
    SmashVehicleWindow(unit.vehicle, 0)
    SmashVehicleWindow(unit.vehicle, 1)
    SmashVehicleWindow(unit.vehicle, 2)
    SmashVehicleWindow(unit.vehicle, 3)
    
    for i, officer in ipairs(unit.officers) do
        if officer.ped and DoesEntityExist(officer.ped) then
            ClearPedTasks(officer.ped)
            TaskLeaveVehicle(officer.ped, unit.vehicle, 16)
            officer.isOnFoot = true
            
            Wait(800)
        end
    end
end

---------------------------------------------------------------------
-- RETORNAR PARA O VEÍCULO
---------------------------------------------------------------------

local function ReturnToVehicle(unitId)
    local unit = ActiveUnits[unitId]
    if not unit or not unit.vehicle or not DoesEntityExist(unit.vehicle) then 
        return 
    end
    
    DebugPrint("Returning to VEHICLE for unit:", unitId)
    
    unit.state = "vehicle_chase"
    
    for i, officer in ipairs(unit.officers) do
        if officer.ped and DoesEntityExist(officer.ped) then
            officer.isOnFoot = false
            ClearPedTasks(officer.ped)
            
            local seat = officer.isDriver and -1 or (i - 2)
            TaskEnterVehicle(officer.ped, unit.vehicle, 10000, seat, 1.0, 1)
            
            Wait(800)
        end
    end
    
    -- Retoma perseguição em veículo
    CreateThread(function()
        Wait(3000)
        if ActiveUnits[unitId] and ActiveUnits[unitId].state == "vehicle_chase" then
            StartVehicleChase(unitId)
        end
    end)
end

---------------------------------------------------------------------
-- ANIMAÇÃO DE ALGEMAR
---------------------------------------------------------------------

local function PlayHandcuffAnimation(policeOfficer, playerPed)
    DebugPrint("Playing handcuff animation...")
    
    if not LoadAnimation(HANDCUFF_ANIMATION_DICT) then
        DebugPrint("Failed to load handcuff animation")
        return false
    end
    
    ClearPedTasks(playerPed)
    ClearPedTasks(policeOfficer)
    
    SetEntityHeading(playerPed, GetEntityHeading(policeOfficer) - 180.0)
    
    TaskPlayAnim(policeOfficer, HANDCUFF_ANIMATION_DICT, HANDCUFF_ANIMATION_NAME, 8.0, -8.0, 5000, 49, 0, false, false, false)
    TaskPlayAnim(playerPed, HANDCUFF_ANIMATION_DICT, "mp_arrest_captured_car", 8.0, -8.0, 5000, 49, 0, false, false, false)
    
    Wait(5000)
    
    RemoveAnimDict(HANDCUFF_ANIMATION_DICT)
    
    return true
end

---------------------------------------------------------------------
-- DIÁLOGOS DO POLICIAL
---------------------------------------------------------------------

local function PlayPoliceDialogue(policeOfficer, crimeType, jailTime)
    DebugPrint("Playing police dialogue...")
    
    local crimeLabels = {
        shooting = "Disparo de arma de fogo",
        DrugSelling = "Tráfico de drogas",
        Robbery = "Roubo Qualificado",
        Murder = "Homicídio",
        AssaultPolice = "Agressão a autoridade policial",
        KillPolice = "Homicídio de Agente Público",
        VehicleTheft = "Furto de Veículo"
    }
    
    local crimeLabel = crimeLabels[crimeType] or "Atividade Suspeita"
    
    TriggerEvent('chat:addMessage', {
        color = {255, 0, 0},
        multiline = true,
        args = {"Policial", POLICE_DIALOGUE.intro}
    })
    
    Wait(2000)
    
    TriggerEvent('chat:addMessage', {
        color = {255, 0, 0},
        multiline = true,
        args = {"Policial", POLICE_DIALOGUE.arrest}
    })
    
    Wait(2000)
    
    local crimeMessage = string.format(POLICE_DIALOGUE.crime_format, crimeLabel, jailTime)
    
    TriggerEvent('chat:addMessage', {
        color = {255, 0, 0},
        multiline = true,
        args = {"Policial", crimeMessage}
    })
    
    Wait(2000)
end

---------------------------------------------------------------------
-- PRENDER JOGADOR
---------------------------------------------------------------------

local function ArrestPlayer(unitId, crimeType, jailTime)
    local unit = ActiveUnits[unitId]
    local playerPed = GetLocalPlayerPed()
    
    if not unit or not unit.officers or #unit.officers == 0 or unit.arrestInProgress then 
        return 
    end
    
    unit.arrestInProgress = true
    
    DebugPrint("Arresting player... Crime:", crimeType, "Jail Time:", jailTime)
    
    local policeOfficer = nil
    for _, off in ipairs(unit.officers) do
        if DoesEntityExist(off.ped) and not IsPedDeadOrDying(off.ped, 1) then
            policeOfficer = off.ped
            break
        end
    end
    
    if not policeOfficer then 
        unit.arrestInProgress = false
        return 
    end
    
    ClearPedTasksImmediately(playerPed)
    ClearPedTasksImmediately(policeOfficer)
    
    PlayHandcuffAnimation(policeOfficer, playerPed)
    PlayPoliceDialogue(policeOfficer, crimeType, jailTime)
    
    Wait(1000)
    
    -- Enviar ao servidor para prender
    TriggerServerEvent('npcpolice:server:arrestPlayer')
    
    Wait(2000)
    
    -- Limpar unidade
    if unit.vehicle and DoesEntityExist(unit.vehicle) then
        DeleteEntity(unit.vehicle)
    end
    
    for _, officer in ipairs(unit.officers) do
        if officer.ped and DoesEntityExist(officer.ped) then
            DeleteEntity(officer.ped)
        end
    end
    
    ActiveUnits[unitId] = nil
    UpdateUnitBlips()
end

---------------------------------------------------------------------
-- LOOP PRINCIPAL DE COMPORTAMENTO DA IA
---------------------------------------------------------------------

local function UpdateUnitBehavior()
    local playerPed = GetLocalPlayerPed()
    local playerCoords = GetPlayerCoords()
    local playerInVehicle = (GetVehiclePedIsIn(playerPed, false) ~= 0)
    
    local isPlayerRendered = IsPlayerSurrendered(playerPed)
    local isPlayerHostile = (IsPedInMeleeCombat(playerPed) or IsPedShooting(playerPed) or IsPlayerFreeAiming(playerPed))
    
    for unitId, unit in pairs(ActiveUnits) do
        if not unit.vehicle or not DoesEntityExist(unit.vehicle) then
            TriggerServerEvent('ai-police:server:unitDestroyed', unitId)
            ActiveUnits[unitId] = nil
            goto continue
        end
        
        local activeOfficerCount = 0
        local primaryOfficerPed = nil
        
        for _, officer in ipairs(unit.officers) do
            if DoesEntityExist(officer.ped) and not IsPedDeadOrDying(officer.ped, 1) then
                activeOfficerCount = activeOfficerCount + 1
                
                if not primaryOfficerPed then 
                    primaryOfficerPed = officer.ped 
                end
                
                -- Comportamento baseado no estado do jogador
                if isPlayerRendered then
                    -- Jogador rendido: guarda arma e se aproxima
                    SetCurrentPedWeapon(officer.ped, GetHashKey("WEAPON_UNARMED"), true)
                    
                    if unit.state == "foot_pursuit" then
                        if not officer.isDriver then
                            TaskGoToEntity(officer.ped, playerPed, -1, 2.0, 2.0, 1073741824, 0)
                        end
                    end
                elseif isPlayerHostile then
                    -- Jogador hostil: combate agressivo
                    SetPedCombatAttributes(officer.ped, 46, true)
                    SetPedCombatAttributes(officer.ped, 3, true)
                    SetPedCombatAttributes(officer.ped, 5, true)
                else
                    -- Jogador fugindo: perseguir
                    if unit.state == "foot_pursuit" then
                        if not officer.isDriver then
                            TaskGoToEntity(officer.ped, playerPed, -1, 3.0, 2.5, 1073741824, 0)
                        end
                    end
                end
            end
        end
        
        -- Se não houver oficiais ativos, remove a unidade
        if activeOfficerCount == 0 then
            TriggerServerEvent('ai-police:server:unitDestroyed', unitId)
            ActiveUnits[unitId] = nil
            goto continue
        end
        
        -- Calcula distância até o jogador
        local leaderCoords = primaryOfficerPed and GetEntityCoords(primaryOfficerPed) or GetEntityCoords(unit.vehicle)
        unit.playerDistance = GetDistance(playerCoords, leaderCoords)
        
        -- Remove spawning se saiu do raio de distância
        if unit.spawning and unit.playerDistance > Config.PoliceAI.VehicleChaseDistance then
            unit.spawning = false
        end
        
        -- Transições de estado
        if playerInVehicle and unit.state == "foot_pursuit" then
            ReturnToVehicle(unitId)
        elseif not playerInVehicle and unit.state == "vehicle_chase" and unit.playerDistance < Config.PoliceAI.FootChaseDistance then
            TransitionToFootPursuit(unitId)
        end
        
        -- Inicia perseguição se ainda não começou
        if not unit.chaseStarted and not unit.spawning then
            StartVehicleChase(unitId)
        end
        
        -- ARREST: Verifica se deve prender o jogador
        if unit.state == "foot_pursuit" and unit.playerDistance <= Config.PoliceAI.ArrestDistance and not unit.arrestInProgress then
            -- Prende se estiver rendido OU se não estiver atacando
            if isPlayerRendered or not isPlayerHostile then
                -- Obtém informações do servidor
                local lastCrime = "Atividade Suspeita"
                local jailTime = 5
                
                -- Tenta usar exports do servidor
                if exports['NpcPolice'] then
                    local successCrime, crime = pcall(function()
                        return exports['NpcPolice']:GetLastCrime()
                    end)
                    
                    local successTime, time = pcall(function()
                        return exports['NpcPolice']:GetJailTime()
                    end)
                    
                    if successCrime and crime then
                        lastCrime = crime
                    end
                    
                    if successTime and time then
                        jailTime = time
                    end
                end
                
                DebugPrint("Arrest triggered for unit:", unitId, "Crime:", lastCrime, "Jail Time:", jailTime)
                ArrestPlayer(unitId, lastCrime, jailTime)
                break
            end
        end
        
        -- Despawn se jogador fugir muito longe
        if unit.playerDistance > 250.0 then
            TriggerServerEvent('ai-police:server:unitDestroyed', unitId)
            ActiveUnits[unitId] = nil
        end
        
        DebugPrint(
            "Unit:",
            unitId,
            "State:",
            unit.state,
            "Distance:",
            math.floor(unit.playerDistance),
            "Officers:",
            activeOfficerCount,
            "Spawning:",
            unit.spawning,
            "Arrest:",
            unit.arrestInProgress
        )
        
        ::continue::
    end
    
    UpdateUnitBlips()
end

---------------------------------------------------------------------
-- EVENTS
---------------------------------------------------------------------

RegisterNetEvent('ai-police:client:spawnUnit', function(data)
    DebugPrint("Event received: spawnUnit")
    SpawnPoliceUnit(data)
end)

RegisterNetEvent('ai-police:client:updateSuspicion', function(suspicion, stars)
    Suspicion = suspicion
    WantedLevel = stars
    DebugPrint("Suspicion updated:", suspicion, "Stars:", stars)
end)

RegisterNetEvent('ai-police:client:removeUnit', function(unitId)
    if ActiveUnits[unitId] then
        local unit = ActiveUnits[unitId]
        
        if unit.vehicle and DoesEntityExist(unit.vehicle) then
            DeleteEntity(unit.vehicle)
        end
        
        for _, officer in ipairs(unit.officers) do
            if officer.ped and DoesEntityExist(officer.ped) then
                DeleteEntity(officer.ped)
            end
        end
        
        ActiveUnits[unitId] = nil
        DebugPrint("Unit removed:", unitId)
        UpdateUnitBlips()
    end
end)

RegisterNetEvent('ai-police:client:clearUnits', function()
    DebugPrint("Clearing all units")
    
    for unitId, unit in pairs(ActiveUnits) do
        if unit.vehicle and DoesEntityExist(unit.vehicle) then
            DeleteEntity(unit.vehicle)
        end
        
        for _, officer in ipairs(unit.officers) do
            if officer.ped and DoesEntityExist(officer.ped) then
                DeleteEntity(officer.ped)
            end
        end
    end
    
    for _, blip in pairs(UnitBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    
    UnitBlips = {}
    ActiveUnits = {}
    UpdateUnitBlips()
    DebugPrint("All units cleared")
end)

---------------------------------------------------------------------
-- THREAD PRINCIPAL
---------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(100)
        
        if Suspicion > 0 or WantedLevel > 0 then
            UpdateUnitBehavior()
        else
            if next(ActiveUnits) then
                ActiveUnits = {}
                UnitBlips = {}
                UpdateUnitBlips()
            end
            Wait(1000)
        end
    end
end)

---------------------------------------------------------------------
-- DETECÇÃO DE DISPAROS
---------------------------------------------------------------------

local lastShotTime = 0

CreateThread(function()
    while true do
        Wait(100)
        
        local playerPed = GetLocalPlayerPed()
        
        if GetSelectedPedWeapon(playerPed) ~= GetHashKey("WEAPON_UNARMED") then
            if IsPlayerFreeAiming(playerPed) or IsPedShooting(playerPed) then
                if GetGameTimer() - lastShotTime > 3000 then
                    TriggerServerEvent('ai-police:server:reportShooting')
                    lastShotTime = GetGameTimer()
                    DebugPrint("Shooting detected")
                end
            end
        end
    end
end)

---------------------------------------------------------------------
-- VERIFICAÇÃO DE CARREGAMENTO
---------------------------------------------------------------------

CreateThread(function()
    while true do
        if LocalPlayer.state.isLoggedIn then
            break
        end
        Wait(1000)
    end
    
    DebugPrint("Player loaded, NPC Police system ready")
end)

---------------------------------------------------------------------
-- INICIALIZAÇÃO
---------------------------------------------------------------------

CreateThread(function()
    Wait(3000)
    
    print("^2================================^7")
    print("^2 NPCPolice Client Initialized ^7")
    print("^2 Sistema AAA Triple A Ativo   ^7")
    print("^2================================^7")
end)
