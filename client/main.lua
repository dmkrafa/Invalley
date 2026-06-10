local QBCore = exports['qb-core']:GetCoreObject()

---------------------------------------------------------------------
-- DADOS PRINCIPAIS
---------------------------------------------------------------------

local PlayerData = {}
local ActiveUnits = {}
local Suspicion = 0
local WantedLevel = 0

---------------------------------------------------------------------
-- CONSTANTES
---------------------------------------------------------------------

local HANDCUFF_ANIMATION = "mp_arrest_paired"
local HANDCUFF_ANIMATION_DICT = "mp_arrest_paired"
local HANDCUFF_ANIMATION_NAME = "cop_p_s_pose_armed_1d"

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
-- OBTER PED DO JOGADOR
---------------------------------------------------------------------

local function GetPlayerPed()
    return PlayerPedId()
end

---------------------------------------------------------------------
-- OBTER COORDENADAS DO JOGADOR
---------------------------------------------------------------------

local function GetPlayerCoords()
    return GetEntityCoords(GetPlayerPed())
end

---------------------------------------------------------------------
-- CALCULAR DISTÂNCIA ENTRE DOIS PONTOS
---------------------------------------------------------------------

local function GetDistance(coords1, coords2)
    return #(coords1 - coords2)
end

---------------------------------------------------------------------
-- CARREGAR MODELO
---------------------------------------------------------------------

local function LoadModel(modelHash)
    RequestModel(GetHashKey(modelHash))
    local timeout = GetGameTimer() + 5000
    
    while not HasModelLoaded(GetHashKey(modelHash)) and GetGameTimer() < timeout do
        Wait(0)
    end
    
    return HasModelLoaded(GetHashKey(modelHash))
end

---------------------------------------------------------------------
-- CARREGAR ANIMAÇÃO
---------------------------------------------------------------------

local function LoadAnimation(dictName)
    RequestAnimDict(dictName)
    local timeout = GetGameTimer() + 5000
    
    while not HasAnimDictLoaded(dictName) and GetGameTimer() < timeout do
        Wait(0)
    end
    
    return HasAnimDictLoaded(dictName)
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
    
    -- Spawn do veículo
    local vehicle = CreateVehicle(
        GetHashKey(vehicleModel),
        coords.x,
        coords.y,
        coords.z,
        heading,
        true,
        false
    )
    
    SetVehicleEngineHealth(vehicle, 1000.0)
    SetVehicleDirtLevel(vehicle, 0.0)
    SmashVehicleWindow(vehicle, 0)
    SmashVehicleWindow(vehicle, 1)
    
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleDoorsShut(vehicle, false)
    
    -- Spawn dos policiais
    local policeOfficers = {}
    
    for i = 1, cops do
        local seatIndex = i - 1
        local ped = CreatePed(4, GetHashKey(pedModel), coords.x, coords.y, coords.z, 0.0, true, false)
        
        if ped and ped > 0 then
            SetBlockingOfNonTemporaryEvents(ped, true)
            SetEntityAsMissionEntity(ped, true, true)
            
            -- Sentar no veículo
            TaskWarpPedIntoVehicle(ped, vehicle, seatIndex)
            
            -- Equipar com arma
            GiveWeaponToPed(ped, GetHashKey("WEAPON_PISTOL"), 256, false, true)
            
            table.insert(policeOfficers, {
                ped = ped,
                seatIndex = seatIndex,
                isOnFoot = false,
                targetPed = nil
            })
        end
    end
    
    ReleaseModelRequest(GetHashKey(vehicleModel))
    ReleaseModelRequest(GetHashKey(pedModel))
    
    local unit = {
        unitId = unitId,
        vehicle = vehicle,
        officers = policeOfficers,
        state = "awaiting_behavior",
        lastState = "awaiting_behavior",
        spawning = true,
        createdAt = GetGameTimer(),
        playerInVehicle = false,
        chaseStarted = false,
        playerDistance = 999,
        lastPlayerCoords = nil,
        pursuitActive = false
    }
    
    ActiveUnits[unitId] = unit
    
    DebugPrint("Police unit spawned successfully")
    
    return true
end

---------------------------------------------------------------------
-- INICIAR PERSEGUIÇÃO EM VEÍCULO
---------------------------------------------------------------------

local function StartVehicleChase(unitId)
    local unit = ActiveUnits[unitId]
    
    if not unit or not unit.vehicle or DoesEntityExist(unit.vehicle) == false then
        return
    end
    
    DebugPrint("Vehicle chase STARTED for unit:", unitId)
    
    unit.state = "vehicle_chase"
    unit.chaseStarted = true
    unit.pursuitActive = true
    
    -- Leader do grupo (motorista)
    local driverOfficer = unit.officers[1]
    if driverOfficer then
        local driver = driverOfficer.ped
        
        -- Iniciar perseguição com TaskVehicleChase
        TaskVehicleChase(driver, GetPlayerPed())
        SetDriverAbility(driver, 1.0)
        SetDriveAggressively(driver, 1.0)
        
        -- Garantir que o motorista está no banco do motorista
        if GetPedInVehicleSeat(unit.vehicle, -1) ~= driver then
            TaskWarpPedIntoVehicle(driver, unit.vehicle, -1)
        end
    end
    
    -- Outros policiais disparam arma
    for i = 2, #unit.officers do
        local officer = unit.officers[i]
        if officer.ped and DoesEntityExist(officer.ped) then
            -- Dispara na direção do jogador
            local playerCoords = GetPlayerCoords()
            TaskStartScenarioInPlace(officer.ped, "WORLD_HUMAN_STUPID_IDLE", 0, true)
            TaskTurnCharacterInDirection(officer.ped, playerCoords.x, playerCoords.y, 1000)
        end
    end
end

---------------------------------------------------------------------
-- VERIFICAR ESTADO DO POLICIAL
---------------------------------------------------------------------

local function IsPlayerInVehicle(playerPed)
    return GetVehiclePedIsIn(playerPed, false) ~= 0
end

local function IsPlayerOnFoot(playerPed)
    return not IsPlayerInVehicle(playerPed)
end

---------------------------------------------------------------------
-- POLICIAL SAI DO VEÍCULO E PERSEGUE A PÉ
---------------------------------------------------------------------

local function TransitionToFootPursuit(unitId)
    local unit = ActiveUnits[unitId]
    
    if not unit or not unit.vehicle then
        return
    end
    
    DebugPrint("Transitioning to FOOT PURSUIT for unit:", unitId)
    
    unit.state = "foot_pursuit"
    unit.pursuitActive = true
    
    -- Todos os policiais saem do veículo
    for i, officer in ipairs(unit.officers) do
        if officer.ped and DoesEntityExist(officer.ped) then
            TaskLeaveVehicle(officer.ped, unit.vehicle, 0)
            officer.isOnFoot = true
            
            -- Esperar policial sair do veículo
            Wait(1500)
            
            -- Policial persegue jogador a pé
            TaskStartScenarioInPlace(officer.ped, "WORLD_HUMAN_MOBILE_FILM_SHOCKING", 0, true)
            TaskTurnCharacterInDirection(officer.ped, GetPlayerCoords().x, GetPlayerCoords().y, 1000)
        end
    end
end

---------------------------------------------------------------------
-- POLICIAL VOLTA PARA O VEÍCULO
---------------------------------------------------------------------

local function ReturnToVehicle(unitId)
    local unit = ActiveUnits[unitId]
    
    if not unit or not unit.vehicle or DoesEntityExist(unit.vehicle) == false then
        return
    end
    
    DebugPrint("Returning to VEHICLE for unit:", unitId)
    
    unit.state = "vehicle_chase"
    
    for i, officer in ipairs(unit.officers) do
        if officer.ped and DoesEntityExist(officer.ped) then
            officer.isOnFoot = false
            
            -- Voltar para o veículo
            TaskEnterVehicle(officer.ped, unit.vehicle, 10000, i - 1, 1.0, 1)
            
            Wait(1000)
            
            -- Retomar perseguição em veículo
            if i == 1 then
                TaskVehicleChase(officer.ped, GetPlayerPed())
                SetDriverAbility(officer.ped, 1.0)
            end
        end
    end
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
    
    -- Parar o jogador
    TaskStartScenarioInPlace(playerPed, "WORLD_HUMAN_STUPID_IDLE", 0, true)
    
    -- Animar o policial algemando
    TaskPlayAnim(
        policeOfficer,
        HANDCUFF_ANIMATION_DICT,
        HANDCUFF_ANIMATION_NAME,
        8.0,
        -8.0,
        5000,
        49,
        0,
        false,
        false,
        false
    )
    
    Wait(5000)
    
    RemoveAnimDict(HANDCUFF_ANIMATION_DICT)
    
    return true
end

---------------------------------------------------------------------
-- DIÁLOGOS DO POLICIAL
---------------------------------------------------------------------

local function PlayPoliceDialogue(policeOfficer, crimeType, jailTime)
    DebugPrint("Playing police dialogue...")
    
    -- Frase 1: Intro
    TriggerEvent('chat:addMessage', {
        color = {255, 0, 0},
        multiline = true,
        args = {"Policial", POLICE_DIALOGUE.intro}
    })
    
    Wait(2000)
    
    -- Frase 2: Arrest
    TriggerEvent('chat:addMessage', {
        color = {255, 0, 0},
        multiline = true,
        args = {"Policial", POLICE_DIALOGUE.arrest}
    })
    
    Wait(2000)
    
    -- Frase 3: Crime e tempo de prisão
    local crimeLabel = GetCrimeLabel(crimeType)
    local crimeMessage = string.format(POLICE_DIALOGUE.crime_format, crimeLabel, jailTime)
    
    TriggerEvent('chat:addMessage', {
        color = {255, 0, 0},
        multiline = true,
        args = {"Policial", crimeMessage}
    })
    
    Wait(2000)
end

---------------------------------------------------------------------
-- OBTER LABEL DO CRIME
---------------------------------------------------------------------

local function GetCrimeLabel(crimeType)
    local crimeLabels = {
        shooting = "Disparo de arma de fogo",
        DrugSelling = "Tráfico de drogas",
        Robbery = "Roubo",
        Murder = "Homicídio",
        AssaultPolice = "Agressão a policial",
        KillPolice = "Homicídio de policial",
        VehicleTheft = "Roubo de veículo"
    }
    
    return crimeLabels[crimeType] or "Crime desconhecido"
end

---------------------------------------------------------------------
-- PRENDER JOGADOR
---------------------------------------------------------------------

local function ArrestPlayer(unitId, crimeType, jailTime)
    local unit = ActiveUnits[unitId]
    local playerPed = GetPlayerPed()
    
    if not unit or not unit.officers or #unit.officers == 0 then
        return
    end
    
    DebugPrint("Arresting player... Crime:", crimeType, "Jail Time:", jailTime)
    
    local policeOfficer = unit.officers[1].ped
    
    -- Policial se aproxima do jogador
    local playerCoords = GetEntityCoords(playerPed)
    TaskGoStraightToCoord(policeOfficer, playerCoords.x, playerCoords.y, playerCoords.z, 1.0, -1, 0.0, 0.0)
    
    -- Esperar policial se aproximar
    local maxWait = GetGameTimer() + 10000
    while GetDistance(GetEntityCoords(policeOfficer), playerCoords) > 2.0 and GetGameTimer() < maxWait do
        Wait(100)
    end
    
    -- Parar o jogador
    TaskStartScenarioInPlace(playerPed, "WORLD_HUMAN_MOBILE_FILM_SHOCKING", 0, true)
    ClearPedTasksImmediately(playerPed)
    
    -- Animar algemadura
    PlayHandcuffAnimation(policeOfficer, playerPed)
    
    -- Diálogos
    PlayPoliceDialogue(policeOfficer, crimeType, jailTime)
    
    Wait(3000)
    
    -- Enviar ao cliente para ir para a prisão
    TriggerServerEvent('npcpolice:server:arrestPlayer')
    
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
end

---------------------------------------------------------------------
-- LOOP PRINCIPAL DE PERSEGUIÇÃO
---------------------------------------------------------------------

local function UpdateUnitBehavior()
    for unitId, unit in pairs(ActiveUnits) do
        if not unit.vehicle or not DoesEntityExist(unit.vehicle) then
            ActiveUnits[unitId] = nil
            goto continue
        end
        
        local playerPed = GetPlayerPed()
        local playerCoords = GetPlayerCoords()
        local vehicleCoords = GetEntityCoords(unit.vehicle)
        
        -- Calcular distância
        unit.playerDistance = GetDistance(playerCoords, vehicleCoords)
        
        -- ATUALIZAR ESTADO
        local playerInVehicle = IsPlayerInVehicle(playerPed)
        
        if unit.spawning and unit.playerDistance > Config.PoliceAI.VehicleChaseDistance then
            unit.spawning = false
        end
        
        -- Se jogador entrou em um veículo e policial estava a pé
        if playerInVehicle and unit.state == "foot_pursuit" then
            ReturnToVehicle(unitId)
        end
        
        -- Se jogador está a pé e policial está perto em veículo
        if not playerInVehicle and unit.state == "vehicle_chase" and unit.playerDistance < Config.PoliceAI.FootChaseDistance then
            TransitionToFootPursuit(unitId)
        end
        
        -- Iniciar perseguição se parado
        if not unit.chaseStarted and not unit.spawning then
            StartVehicleChase(unitId)
        end
        
        -- Verificar se o jogador saiu da área de perseguição
        if unit.pursuitActive and unit.playerDistance > 200 then
            DebugPrint("Player escaped from unit:", unitId)
            TriggerServerEvent('ai-police:server:unitDestroyed', unitId)
            ActiveUnits[unitId] = nil
        end
        
        -- Verificar se o policial chegou perto para prender
        if unit.state == "foot_pursuit" and unit.playerDistance < Config.PoliceAI.ArrestDistance then
            TriggerServerEvent('npcpolice:server:arrestPlayer')
            local lastCrime = exports['ai-police']:GetLastCrime() or "Atividade Suspeita"
            local jailTime = exports['ai-police']:GetJailTime() or 5
            
            Wait(500)
            ArrestPlayer(unitId, lastCrime, jailTime)
        end
        
        unit.lastState = unit.state
        
        DebugPrint(
            "Unit:",
            unitId,
            "State:",
            unit.state,
            "Distance:",
            math.floor(unit.playerDistance),
            "LastState:",
            unit.lastState,
            "Spawning:",
            unit.spawning
        )
        
        ::continue::
    end
end

---------------------------------------------------------------------
-- EVENT: SPAWN UNIT
---------------------------------------------------------------------

RegisterNetEvent('ai-police:client:spawnUnit', function(data)
    SpawnPoliceUnit(data)
end)

---------------------------------------------------------------------
-- EVENT: UPDATE SUSPICION
---------------------------------------------------------------------

RegisterNetEvent('ai-police:client:updateSuspicion', function(suspicion, stars)
    Suspicion = suspicion
    WantedLevel = stars
    
    DebugPrint("Suspicion updated:", suspicion, "Stars:", stars)
end)

---------------------------------------------------------------------
-- EVENT: REMOVE UNIT
---------------------------------------------------------------------

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
    end
end)

---------------------------------------------------------------------
-- EVENT: CLEAR ALL UNITS
---------------------------------------------------------------------

RegisterNetEvent('ai-police:client:clearUnits', function()
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
    
    ActiveUnits = {}
    DebugPrint("All units cleared")
end)

---------------------------------------------------------------------
-- THREAD PRINCIPAL
---------------------------------------------------------------------

CreateThread(function()
    while true do
        Wait(100)
        
        UpdateUnitBehavior()
    end
end)

---------------------------------------------------------------------
-- REGISTRAR CRIME
---------------------------------------------------------------------

RegisterNetEvent('ai-police:client:reportCrime', function(crime)
    TriggerServerEvent('ai-police:server:reportCrime', crime)
end)

---------------------------------------------------------------------
-- DETECTAR DISPARO
---------------------------------------------------------------------

local lastShotTime = 0

CreateThread(function()
    while true do
        Wait(100)
        
        local playerPed = GetPlayerPed()
        
        if GetSelectedPedWeapon(playerPed) ~= GetHashKey("WEAPON_UNARMED") then
            if IsPlayerFreeAiming(playerPed) or IsCharacterShooting(playerPed) then
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
-- FUNÇÃO AUXILIAR
---------------------------------------------------------------------

local function IsCharacterShooting(ped)
    return IsPedShooting(ped)
end

---------------------------------------------------------------------
-- PLAYER LOADED
---------------------------------------------------------------------

CreateThread(function()
    while true do
        if PlayerData and PlayerData.citizenid then
            break
        end
        
        Wait(100)
    end
    
    DebugPrint("Player loaded, NPC Police system ready")
end)
