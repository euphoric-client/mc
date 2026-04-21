do
	local function stub(t)
		if type(t) ~= "table" then
			return
		end
		t.isfolder = t.isfolder or function()
			return false
		end
		t.makefolder = t.makefolder or function() end
		t.isfile = t.isfile or function()
			return false
		end
		t.writefile = t.writefile or function() end
		t.readfile = t.readfile or function()
			return ""
		end
		t.listfiles = t.listfiles or function()
			return {}
		end
		t.delfile = t.delfile or function() end
		t.cloneref = t.cloneref or function(o)
			return o
		end
		t.getcustomasset = t.getcustomasset or function(s)
			return s
		end
		t.gethui = t.gethui or function()
			return game:GetService("CoreGui")
		end
	end
	stub(_G)
	_G.getgenv = _G.getgenv or function()
		return _G
	end
	if type(getgenv) == "function" then
		stub(getgenv())
	else
		stub(_G.getgenv())
	end
end

local function getge()
	if type(getgenv) == "function" then
		return getgenv()
	end
	return _G.getgenv and _G.getgenv() or _G
end

assert(type(getgenv) == "function", "kpop demon: getgenv required (executor only)")
assert(type(loadstring) == "function", "kpop demon: loadstring required (executor only)")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ClientRace = require(Modules.Client.ClientRace)
local Races = require(Modules.Shared.Races.Races)
local Network = require(Modules.Modules.Network)
local RaceDB = require(Modules.DB.RaceDB)

local function resolveConfig()
	local ge = getge()
	local c = ge and ge.KpopDemonConfig
	if type(c) == "table" then
		return c
	end
	error("kpop demon: getgenv().KpopDemonConfig missing (run loader.lua from git)")
end

local function resolveHotkeys()
	local ge = getge()
	local h = ge and ge.KpopDemonHotkeys
	if type(h) == "table" then
		return h
	end
	error("kpop demon: getgenv().KpopDemonHotkeys missing (run loader.lua from git)")
end

local Config = resolveConfig()
local Hotkeys = resolveHotkeys()

local function loadRemoteLibrary()
	local url = Config.LibraryRemoteUrl
	if type(url) ~= "string" or url == "" then
		return nil
	end
	local ok, lib = pcall(function()
		return loadstring(game:HttpGet(url, true))()
	end)
	if ok and type(lib) == "table" then
		return lib
	end
	return nil
end

local function resolveLibrary()
	local lib = loadRemoteLibrary()
	if lib then
		return lib
	end
	error("kpop demon: Library HttpGet failed (check LibraryRemoteUrl in KpopDemonConfig on git)")
end

local Library = resolveLibrary()

local KpopDemon = {}

local localPlayer = Players.LocalPlayer
local labels = {}
local lastTeleportClock = 0
local lastChainTeleportClock = 0
local speedMultiplier = Config.SpeedMultiplierDefault
local steeringSensitivity = Config.SteeringSensitivityDefault
local lastSoloQueueClock = 0
local characterConnections = {}
local watchedRacesRoot = nil
local tuneBaselines = {}
local lastTuneScript = nil
local raceDisplayNames = {}
local mainWindow = nil
local automationState = {
	autoFarm = false,
	teleportChain = false,
	autoDriveV1 = false,
	autoDriveV2 = false,
	autoQueueSolo = false,
	selectedRaceId = "Race5",
}
local steerPulseAccum = 0
local keysVirtualDown = {
	[Enum.KeyCode.W] = false,
	[Enum.KeyCode.A] = false,
	[Enum.KeyCode.D] = false,
}

local POWER_KEYS = {
	Horsepower = true,
	E_Horsepower = true,
	E_Torque = true,
}
local STEER_KEYS = {
	SteerSpeed = true,
	SteerRatio = true,
	MinSteer = true,
}

local function automationAllowed()
	if not Config.AllowClientAutomation then
		return false
	end
	if Config.RequireStudioForAutomation and not RunService:IsStudio() then
		return false
	end
	return true
end

local function mphApproxFromStudsPerSec(studsPerSec)
	return studsPerSec * 0.626
end

local function mergeStaticRaceNames()
	for id, row in pairs(RaceDB.Races) do
		if type(row) == "table" and row.Name then
			raceDisplayNames[id] = row.Name
		end
	end
	for id, row in pairs(Config.Races) do
		if type(row) == "table" and row.Name then
			raceDisplayNames[id] = row.Name
		end
	end
end

local function refreshRaceNamesFromWorkspace()
	local root = Workspace:FindFirstChild("Races")
	if not root then
		return
	end
	for _, child in root:GetChildren() do
		if child:IsA("Folder") then
			local cfg = child:FindFirstChild("Config")
			local rn = cfg and cfg:FindFirstChild("RaceName")
			if rn and rn:IsA("StringValue") and rn.Value ~= "" then
				raceDisplayNames[child.Name] = rn.Value
			end
		end
	end
end

local function bindWorkspaceRacesWatcher()
	local root = Workspace:FindFirstChild("Races")
	if not root or watchedRacesRoot == root then
		return
	end
	watchedRacesRoot = root
	root.ChildAdded:Connect(function()
		task.defer(refreshRaceNamesFromWorkspace)
	end)
	root.ChildRemoved:Connect(function()
		task.defer(refreshRaceNamesFromWorkspace)
	end)
end

local function raceFolderId(raceOrFolder)
	if not raceOrFolder then
		return nil
	end
	if typeof(raceOrFolder) == "Instance" then
		return raceOrFolder.Name
	end
	if typeof(raceOrFolder) == "table" then
		if type(raceOrFolder.Id) == "string" and raceOrFolder.Id ~= "" then
			return raceOrFolder.Id
		end
		local folder = raceOrFolder.Folder
		if folder and typeof(folder) == "Instance" then
			return folder.Name
		end
	end
	return nil
end

local function raceLobbyLabel(raceOrFolder)
	local id = raceFolderId(raceOrFolder)
	if not id then
		return "—"
	end
	local label = raceDisplayNames[id]
	if label and label ~= "" then
		return label
	end
	return id
end

local function findTuneModule(carModel)
	if not carModel then
		return nil
	end
	local tune = carModel:FindFirstChild("A-Chassis Tune", true)
	if tune and tune:IsA("ModuleScript") then
		return tune
	end
	local alt = carModel:FindFirstChild("Tuner", true)
	if alt and alt:IsA("ModuleScript") then
		return alt
	end
	return nil
end

local function captureBaseline(tuneScript, tune)
	local b = {}
	for key in POWER_KEYS do
		local v = tune[key]
		if type(v) == "number" then
			b[key] = v
		end
	end
	for key in STEER_KEYS do
		local v = tune[key]
		if type(v) == "number" then
			b[key] = v
		end
	end
	tuneBaselines[tuneScript] = b
end

local function restoreTuneToBaseline(tuneScript, tune)
	local b = tuneBaselines[tuneScript]
	if not b or not tune then
		return
	end
	for key, base in b do
		tune[key] = base
	end
end

local function reapplyVehicleTune()
	if not lastTuneScript then
		return
	end
	if not (Config.ApplySpeedMultiplierToChassisTune or Config.ApplySteeringTune) then
		return
	end
	local ok, tune = pcall(require, lastTuneScript)
	if not ok or typeof(tune) ~= "table" then
		return
	end
	restoreTuneToBaseline(lastTuneScript, tune)
	local b = tuneBaselines[lastTuneScript]
	if not b then
		return
	end
	for key, base in b do
		if POWER_KEYS[key] and Config.ApplySpeedMultiplierToChassisTune and type(base) == "number" then
			tune[key] = base * speedMultiplier
		elseif STEER_KEYS[key] and Config.ApplySteeringTune and type(base) == "number" then
			tune[key] = base * steeringSensitivity
		end
	end
end

local function bindVehicleTuneForSeat(carModel)
	if not (Config.ApplySpeedMultiplierToChassisTune or Config.ApplySteeringTune) then
		return
	end
	local tuneScript = findTuneModule(carModel)
	if not tuneScript then
		return
	end
	local ok, tune = pcall(require, tuneScript)
	if not ok or typeof(tune) ~= "table" then
		return
	end
	if lastTuneScript and lastTuneScript ~= tuneScript then
		local prevOk, prevTune = pcall(require, lastTuneScript)
		if prevOk and typeof(prevTune) == "table" then
			restoreTuneToBaseline(lastTuneScript, prevTune)
		end
	end
	lastTuneScript = tuneScript
	if not tuneBaselines[tuneScript] then
		captureBaseline(tuneScript, tune)
	end
	reapplyVehicleTune()
end

local function clearVehicleTuneBinding()
	if lastTuneScript then
		local ok, tune = pcall(require, lastTuneScript)
		if ok and typeof(tune) == "table" then
			restoreTuneToBaseline(lastTuneScript, tune)
		end
	end
	lastTuneScript = nil
end

local function readTuneSnapshot(carModel)
	local tuneScript = findTuneModule(carModel)
	if not tuneScript then
		return nil
	end
	local ok, tune = pcall(require, tuneScript)
	if not ok or typeof(tune) ~= "table" then
		return nil
	end
	return {
		Horsepower = tune.Horsepower,
		PeakRPM = tune.PeakRPM,
		Redline = tune.Redline,
		SteerSpeed = tune.SteerSpeed,
		SteerRatio = tune.SteerRatio,
		SteerDecay = tune.SteerDecay,
		MinSteer = tune.MinSteer,
	}
end

local function racerEntryForLocalPlayer()
	local race = ClientRace.ClientRace
	if not race then
		return nil, nil
	end
	local entry = race.Racers:FindFirstChild(localPlayer.Name)
	return race, entry
end

local function countWorkspaceRaceFolders()
	local root = Workspace:FindFirstChild("Races")
	if not root then
		return 0
	end
	local n = 0
	for _, c in root:GetChildren() do
		if c:IsA("Folder") and c:FindFirstChild("QueueRegion") then
			n += 1
		end
	end
	return n
end

local function listSelectableRaceIds()
	local seen = {}
	local ordered = {}
	local root = Workspace:FindFirstChild("Races")
	if root then
		for _, c in root:GetChildren() do
			if c:IsA("Folder") and c:FindFirstChild("QueueRegion") and not seen[c.Name] then
				seen[c.Name] = true
				table.insert(ordered, c.Name)
			end
		end
	end
	for id in pairs(Config.Races) do
		if not seen[id] then
			seen[id] = true
			table.insert(ordered, id)
		end
	end
	table.sort(ordered)
	return ordered
end

local function getRacePhaseText()
	local r = ClientRace.ClientRace
	if r and r.Folder then
		local st = r.Folder:FindFirstChild("State")
		if st and st:IsA("StringValue") then
			return st.Value
		end
	end
	if Races.GetRaceFromPlayer(localPlayer) then
		return "lobby"
	end
	return "idle"
end

local function inDriveSeatForRace()
	local hum = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
	local s = hum and hum.SeatPart
	return s and s:IsA("VehicleSeat") and s.Name == "DriveSeat"
end

local function tryAutoSoloQueue()
	if not automationState.autoQueueSolo then
		return
	end
	if not automationAllowed() then
		return
	end
	if ClientRace.IsInRace then
		return
	end
	if Races.GetRaceFromPlayer(localPlayer) then
		return
	end
	if not inDriveSeatForRace() then
		return
	end
	local rid = automationState.selectedRaceId
	if type(rid) ~= "string" or rid == "" then
		return
	end
	local now = os.clock()
	if now - lastSoloQueueClock < Config.SoloQueueCooldownSeconds then
		return
	end
	lastSoloQueueClock = now
	Network.FireServer("StartSoloRace", rid)
end

local function getCheckpointWorldPosition(race, entry)
	if not race or not entry then
		return nil
	end
	local folder = race.Folder
	if not folder then
		return nil
	end
	local holder = folder:FindFirstChild("Checkpoints")
	if not holder then
		return nil
	end
	local cur = tonumber(entry:GetAttribute("Checkpoint")) or 0
	local nextNum = cur + 1
	local function partWorldPos(inst)
		if inst:IsA("BasePart") then
			return inst.Position
		end
		if inst:IsA("Model") then
			return inst:GetPivot().Position
		end
		if inst:IsA("Folder") then
			local p = inst:FindFirstChildWhichIsA("BasePart", true)
			if p then
				return p.Position
			end
		end
		return nil
	end
	for _, ch in holder:GetChildren() do
		local n = tonumber(ch.Name)
		if n == nextNum then
			local p = partWorldPos(ch)
			if p then
				return p
			end
		end
	end
	return nil
end

local function sendKey(k, isDown)
	VirtualInputManager:SendKeyEvent(isDown, k, false, false)
	keysVirtualDown[k] = isDown
end

local function releaseAllVirtualKeys()
	for k, down in pairs(keysVirtualDown) do
		if down then
			VirtualInputManager:SendKeyEvent(false, k, false, false)
			keysVirtualDown[k] = false
		end
	end
end

local function clampSpeedMultiplier(v)
	return math.clamp(v, Config.SpeedMultiplierMin, Config.SpeedMultiplierMax)
end

local function setSpeedMultiplier(newVal)
	newVal = clampSpeedMultiplier(newVal)
	speedMultiplier = newVal
	reapplyVehicleTune()
end

local function clampSteeringSensitivity(v)
	return math.clamp(v, Config.SteeringSensitivityMin, Config.SteeringSensitivityMax)
end

local function setSteeringSensitivity(newVal)
	steeringSensitivity = clampSteeringSensitivity(newVal)
	reapplyVehicleTune()
end

local function nudgeSpeedMultiplier(delta)
	setSpeedMultiplier(speedMultiplier + delta)
end

local function tryTeleportCheckpointManual()
	local race = ClientRace.ClientRace
	if not race then
		return
	end
	if race.Folder.State.Value ~= "Racing" then
		return
	end
	local now = os.clock()
	if now - lastTeleportClock < Config.TeleportCooldownSeconds then
		return
	end
	lastTeleportClock = now
	lastChainTeleportClock = now
	Network.FireServer("TeleportCheckpoint")
end

local function tryTeleportCheckpointChain()
	local race = ClientRace.ClientRace
	if not race then
		return
	end
	if race.Folder.State.Value ~= "Racing" then
		return
	end
	local now = os.clock()
	if now - lastChainTeleportClock < Config.TeleportChainInterval then
		return
	end
	lastChainTeleportClock = now
	lastTeleportClock = now
	Network.FireServer("TeleportCheckpoint")
end

local function driveSeatCFrame(car)
	if not car then
		return nil
	end
	local seat = car:FindFirstChild("DriveSeat", true)
	if seat and seat:IsA("VehicleSeat") then
		return seat.WorldCFrame
	end
	local hum = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
	local sp = hum and hum.SeatPart
	if sp and sp:IsA("VehicleSeat") then
		return sp.WorldCFrame
	end
	return nil
end

local function runAutoDriveStep(dt)
	if not automationAllowed() then
		return
	end
	local race, entry = racerEntryForLocalPlayer()
	if not race or not entry then
		releaseAllVirtualKeys()
		return
	end
	if race.Folder.State.Value ~= "Racing" then
		releaseAllVirtualKeys()
		return
	end
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat or not seat:IsA("VehicleSeat") then
		releaseAllVirtualKeys()
		return
	end
	local car = seat:FindFirstAncestorWhichIsA("Model")
	local target = getCheckpointWorldPosition(race, entry)
	if not target then
		sendKey(Enum.KeyCode.W, true)
		return
	end
	local cf = driveSeatCFrame(car)
	if not cf then
		return
	end
	local flatFwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if flatFwd.Magnitude < 1e-3 then
		return
	end
	flatFwd = flatFwd.Unit
	local toT = Vector3.new(target.X - cf.Position.X, 0, target.Z - cf.Position.Z)
	if toT.Magnitude < 1e-2 then
		sendKey(Enum.KeyCode.W, false)
		sendKey(Enum.KeyCode.A, false)
		sendKey(Enum.KeyCode.D, false)
		return
	end
	toT = toT.Unit
	local crossY = flatFwd.X * toT.Z - flatFwd.Z * toT.X
	local dot = math.clamp(flatFwd:Dot(toT), -1, 1)
	local angle = math.deg(math.acos(dot))
	local pulse = automationState.autoDriveV2 and Config.AutoDriveV2SteerPulse or Config.AutoDriveV1SteerPulse
	steerPulseAccum += dt
	local pulseOn = steerPulseAccum % (pulse * 2) < pulse
	local distFlat = (cf.Position - target) * Vector3.new(1, 0, 1)
	if distFlat.Magnitude > Config.AutoDriveMinThrottleDistance then
		sendKey(Enum.KeyCode.W, true)
	else
		sendKey(Enum.KeyCode.W, false)
	end
	if math.abs(crossY) < 0.05 and angle < 8 then
		sendKey(Enum.KeyCode.A, false)
		sendKey(Enum.KeyCode.D, false)
		return
	end
	if automationState.autoDriveV2 then
		if crossY > 0 then
			sendKey(Enum.KeyCode.A, pulseOn)
			sendKey(Enum.KeyCode.D, false)
		else
			sendKey(Enum.KeyCode.D, pulseOn)
			sendKey(Enum.KeyCode.A, false)
		end
	else
		if crossY > 0 then
			sendKey(Enum.KeyCode.A, true)
			sendKey(Enum.KeyCode.D, false)
		else
			sendKey(Enum.KeyCode.D, true)
			sendKey(Enum.KeyCode.A, false)
		end
	end
end

local function buildLibraryUi()
	Library.Theme["Accent"] = Color3.fromRGB(255, 105, 180)
	Library.Theme["AccentGradient"] = Color3.fromRGB(255, 140, 200)

	local Window = Library:Window({
		Name = "kpop demon",
		SubName = "Midnight Chasers",
		Logo = "120959262762131",
	})

	local raceIds = listSelectableRaceIds()
	if #raceIds == 0 then
		table.insert(raceIds, "Race5")
	end
	local defaultRace = raceIds[1]
	for _, id in ipairs(raceIds) do
		if id == automationState.selectedRaceId then
			defaultRace = id
			break
		end
	end
	automationState.selectedRaceId = defaultRace

	Window:Category("Overview")
	local Overview = Window:Page({
		Name = "Status",
		Icon = "123944728972740",
	})
	local Live = Overview:Section({
		Name = "Race session",
		Description = "phase, speed, checkpoints",
		Icon = "138827881557940",
		Side = 1,
	})
	labels.phase = Live:Label("phase: idle")
	labels.mult = Live:Label("tune mult: —")
	labels.speed = Live:Label("speed: —")
	labels.tune = Live:Label("tune: —")
	labels.race = Live:Label("lobby race: —")
	labels.racesCount = Live:Label("workspace races: —")
	labels.state = Live:Label("active: —")
	labels.checkpoint = Live:Label("checkpoint: —")

	Window:Category("Tuning")
	local TunePage = Window:Page({
		Name = "Drive",
		Icon = "134236649319095",
	})
	local PowerSec = TunePage:Section({
		Name = "Power",
		Description = "Horsepower, E_Horsepower, E_Torque vs baselines",
		Icon = "108839695397679",
		Side = 1,
	})
	PowerSec:Toggle({
		Name = "Apply power multiplier to chassis tune",
		Flag = "KpopApplyPowerTune",
		Default = Config.ApplySpeedMultiplierToChassisTune,
		Callback = function(v)
			Config.ApplySpeedMultiplierToChassisTune = v
			reapplyVehicleTune()
		end,
	})
	PowerSec:Slider({
		Name = "Speed (power) multiplier",
		Flag = "KpopSpeedMult",
		Min = Config.SpeedMultiplierMin,
		Max = Config.SpeedMultiplierMax,
		Default = speedMultiplier,
		Decimals = 2,
		Suffix = "x",
		Callback = function(v)
			setSpeedMultiplier(v)
		end,
	})
	local SteerSec = TunePage:Section({
		Name = "Steering",
		Description = "SteerSpeed, SteerRatio, MinSteer vs baselines",
		Icon = "126497581491926",
		Side = 1,
	})
	SteerSec:Toggle({
		Name = "Apply steering sensitivity to chassis tune",
		Flag = "KpopApplySteerTune",
		Default = Config.ApplySteeringTune,
		Callback = function(v)
			Config.ApplySteeringTune = v
			reapplyVehicleTune()
		end,
	})
	SteerSec:Slider({
		Name = "Steering sensitivity",
		Flag = "KpopSteerSens",
		Min = Config.SteeringSensitivityMin,
		Max = Config.SteeringSensitivityMax,
		Default = steeringSensitivity,
		Decimals = 2,
		Suffix = "x",
		Callback = function(v)
			setSteeringSensitivity(v)
		end,
	})
	local AutoInputSec = TunePage:Section({
		Name = "Automation timing",
		Description = "teleport cadence and virtual steer pulses",
		Icon = "103180437044643",
		Side = 1,
	})
	AutoInputSec:Slider({
		Name = "Teleport chain interval",
		Flag = "KpopTpInterval",
		Min = Config.TeleportCooldownSeconds,
		Max = 20,
		Default = Config.TeleportChainInterval,
		Decimals = 2,
		Suffix = "s",
		Callback = function(v)
			Config.TeleportChainInterval = v
		end,
	})
	AutoInputSec:Slider({
		Name = "Auto drive V1 steer pulse",
		Flag = "KpopV1Pulse",
		Min = 0.02,
		Max = 0.35,
		Default = Config.AutoDriveV1SteerPulse,
		Decimals = 3,
		Suffix = "s",
		Callback = function(v)
			Config.AutoDriveV1SteerPulse = v
		end,
	})
	AutoInputSec:Slider({
		Name = "Auto drive V2 steer pulse",
		Flag = "KpopV2Pulse",
		Min = 0.02,
		Max = 0.25,
		Default = Config.AutoDriveV2SteerPulse,
		Decimals = 3,
		Suffix = "s",
		Callback = function(v)
			Config.AutoDriveV2SteerPulse = v
		end,
	})
	AutoInputSec:Slider({
		Name = "Min distance before full throttle",
		Flag = "KpopThrottleDist",
		Min = 8,
		Max = 200,
		Default = Config.AutoDriveMinThrottleDistance,
		Decimals = 0,
		Suffix = "stu",
		Callback = function(v)
			Config.AutoDriveMinThrottleDistance = v
		end,
	})

	Window:Category("Farm")
	local Farm = Window:Page({
		Name = "Auto",
		Icon = "108839695397679",
	})
	local QueueSec = Farm:Section({
		Name = "Queue",
		Description = "StartSoloRace with RaceId",
		Icon = "126497581491926",
		Side = 1,
	})
	QueueSec:Dropdown({
		Name = "Race to run",
		Flag = "KpopRacePick",
		Default = defaultRace,
		Items = raceIds,
		Multi = false,
		Callback = function(v)
			if type(v) == "string" then
				automationState.selectedRaceId = v
			elseif type(v) == "table" and v[1] then
				automationState.selectedRaceId = v[1]
			end
		end,
	})
	QueueSec:Toggle({
		Name = "Auto queue solo (selected race)",
		Flag = "KpopAutoSolo",
		Default = false,
		Callback = function(v)
			automationState.autoQueueSolo = v
		end,
	})

	local BotSec = Farm:Section({
		Name = "Farm bot",
		Description = "teleport only while Racing; drive only while Racing",
		Icon = "138827881557940",
		Side = 1,
	})
	BotSec:Toggle({
		Name = "Auto farm (solo queue + teleport + drive)",
		Flag = "KpopAutoFarm",
		Default = false,
		Callback = function(v)
			automationState.autoFarm = v
			if v then
				automationState.teleportChain = true
				automationState.autoQueueSolo = true
				if not automationState.autoDriveV1 and not automationState.autoDriveV2 then
					automationState.autoDriveV1 = true
				end
			end
		end,
	})
	BotSec:Toggle({
		Name = "Checkpoint teleport chain",
		Flag = "KpopTpChain",
		Default = false,
		Callback = function(v)
			automationState.teleportChain = v
		end,
	})
	BotSec:Toggle({
		Name = "Auto drive V1 (hold steer)",
		Flag = "KpopDriveV1",
		Default = false,
		Callback = function(v)
			automationState.autoDriveV1 = v
			if v then
				automationState.autoDriveV2 = false
			end
			if not v and not automationState.autoDriveV2 then
				releaseAllVirtualKeys()
			end
		end,
	})
	BotSec:Toggle({
		Name = "Auto drive V2 (pulse steer)",
		Flag = "KpopDriveV2",
		Default = false,
		Callback = function(v)
			automationState.autoDriveV2 = v
			if v then
				automationState.autoDriveV1 = false
			end
			if not v and not automationState.autoDriveV1 then
				releaseAllVirtualKeys()
			end
		end,
	})

	Library:Notification({
		Title = "kpop demon",
		Description = "Home or PageUp toggles menu.",
		Duration = 4,
		Icon = "73789337996373",
	})

	Window:Init()
	return Window
end

function KpopDemon.Init()
end

function KpopDemon.Start()
	mergeStaticRaceNames()
	refreshRaceNamesFromWorkspace()
	bindWorkspaceRacesWatcher()
	if not Workspace:FindFirstChild("Races") then
		Workspace.ChildAdded:Connect(function(ch)
			if ch.Name == "Races" then
				refreshRaceNamesFromWorkspace()
				bindWorkspaceRacesWatcher()
			end
		end)
	end

	lastTeleportClock = -Config.TeleportCooldownSeconds
	lastChainTeleportClock = -Config.TeleportChainInterval

	mainWindow = buildLibraryUi()

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if
			mainWindow
			and (input.KeyCode == Hotkeys.ToggleHud or input.KeyCode == Hotkeys.ToggleMenu)
		then
			mainWindow:SetOpen(not mainWindow.IsOpen)
		elseif input.KeyCode == Hotkeys.TeleportCheckpoint then
			tryTeleportCheckpointManual()
		elseif input.KeyCode == Hotkeys.SpeedMultUp then
			nudgeSpeedMultiplier(Config.SpeedMultiplierStep)
		elseif input.KeyCode == Hotkeys.SpeedMultDown then
			nudgeSpeedMultiplier(-Config.SpeedMultiplierStep)
		end
	end)

	local function clearCharacterConnections()
		for _, c in characterConnections do
			c:Disconnect()
		end
		table.clear(characterConnections)
	end

	local function onCharacterAdded(character)
		clearCharacterConnections()
		clearVehicleTuneBinding()
		local hum = character:WaitForChild("Humanoid", 30)
		if not hum then
			return
		end
		local function handleSeat()
			task.defer(function()
				local seat = hum.SeatPart
				if seat and seat:IsA("VehicleSeat") then
					local car = seat:FindFirstAncestorWhichIsA("Model")
					if car then
						bindVehicleTuneForSeat(car)
					end
				else
					clearVehicleTuneBinding()
				end
			end)
		end
		table.insert(characterConnections, hum:GetPropertyChangedSignal("SeatPart"):Connect(handleSeat))
		table.insert(characterConnections, hum.Seated:Connect(handleSeat))
		handleSeat()
	end

	if localPlayer.Character then
		onCharacterAdded(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(onCharacterAdded)

	task.spawn(function()
		while true do
			task.wait(0.2)
			if automationAllowed() then
				if automationState.autoQueueSolo then
					tryAutoSoloQueue()
				end
				if automationState.teleportChain or automationState.autoFarm then
					tryTeleportCheckpointChain()
				end
			end
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		if labels.phase then
			labels.phase:SetText("phase: " .. getRacePhaseText())
		end
		if labels.mult then
			labels.mult:SetText(
				string.format(
					"power x%.2f (%s) | steer x%.2f (%s)",
					speedMultiplier,
					Config.ApplySpeedMultiplierToChassisTune and "on" or "off",
					steeringSensitivity,
					Config.ApplySteeringTune and "on" or "off"
				)
			)
		end

		local char = localPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		local car = seat and seat:FindFirstAncestorWhichIsA("Model")
		local v = seat and seat.Velocity.Magnitude or 0
		local vScaled = v * speedMultiplier
		local mph = mphApproxFromStudsPerSec(vScaled)
		if labels.speed then
			labels.speed:SetText(
				string.format("speed: %.0f studs/s | ~%.0f mph (x%.2f)", vScaled, mph, speedMultiplier)
			)
		end

		local snap = readTuneSnapshot(car)
		if labels.tune then
			if snap then
				labels.tune:SetText(
					string.format(
						"tune: hp %s steerSpeed %s steerRatio %s",
						tostring(snap.Horsepower),
						tostring(snap.SteerSpeed),
						tostring(snap.SteerRatio)
					)
				)
			else
				labels.tune:SetText("tune: —")
			end
		end

		local lobbyRace = Races.GetRaceFromPlayer(localPlayer)
		if labels.race then
			labels.race:SetText("lobby race: " .. raceLobbyLabel(lobbyRace))
		end
		if labels.racesCount then
			labels.racesCount:SetText("workspace races: " .. tostring(countWorkspaceRaceFolders()))
		end

		local activeRace, entry = racerEntryForLocalPlayer()
		if labels.state and labels.checkpoint then
			if activeRace and entry then
				local st = activeRace.Folder.State.Value
				local cp = entry:GetAttribute("Checkpoint")
				labels.state:SetText("active: " .. raceLobbyLabel(activeRace) .. " | state " .. tostring(st))
				labels.checkpoint:SetText("checkpoint attr: " .. tostring(cp))
			else
				labels.state:SetText("active: —")
				labels.checkpoint:SetText("checkpoint attr: —")
			end
		end

		local wantDrive = automationAllowed()
			and (
				automationState.autoFarm
				or automationState.autoDriveV1
				or automationState.autoDriveV2
			)
		if wantDrive then
			runAutoDriveStep(dt)
		else
			releaseAllVirtualKeys()
		end
	end)
end

local ge = getge()
if not ge.KpopDemonStarted then
	ge.KpopDemonStarted = true
	task.defer(function()
		KpopDemon.Init()
		KpopDemon.Start()
	end)
end

return KpopDemon
