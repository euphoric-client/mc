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
local VirtualUser = game:GetService("VirtualUser")

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
local lastWithPlayerQueueClock = 0
local queuePlayersTeleportedOnce = false
local chainFinishWaitUntil = nil -- set when we need to wait 2 min before teleporting to Finish
local characterConnections = {}
local function disconnectAllCharacterSignals()
	for _, c in characterConnections do
		c:Disconnect()
	end
	table.clear(characterConnections)
end
local watchedRacesRoot = nil
local tuneBaselines = {}
local lastTuneScript = nil
local raceDisplayNames = {}
local mainWindow = nil
local kpopScriptActive = false
local scriptInputConn = nil
local scriptRenderConn = nil
local scriptCharacterAddedConn = nil
local scriptWorkspaceRacesConn = nil
local scriptIdledConn = nil
local raceFolderAddedConn = nil
local raceFolderRemovedConn = nil
local automationState = {
	teleportChain = false,
	autoQueueSolo = false,
	autoQueueWithPlayers = false,
	selectedRaceId = "Race5",
	carNoclip = false,
	autoNoclipWhileRacing = true,
	antiAfk = false,
	waitBeforeFinish = true,
	finishWaitTime = 120,
	disableTraffic = false,
}
local noclipBaselineByPart = {}
local noclipBoundCar = nil
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
	Torque = true,
	Engine_Horsepower = true,
}
local STEER_KEYS = {
	SteerSpeed = true,
	SteerRatio = true,
	MinSteer = true,
	MaxSteer = true,
	SteerDecay = true,
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

local function unbindRaceFolderWatchers()
	if raceFolderAddedConn then
		raceFolderAddedConn:Disconnect()
		raceFolderAddedConn = nil
	end
	if raceFolderRemovedConn then
		raceFolderRemovedConn:Disconnect()
		raceFolderRemovedConn = nil
	end
	watchedRacesRoot = nil
end

local function bindWorkspaceRacesWatcher()
	local root = Workspace:FindFirstChild("Races")
	if not root or watchedRacesRoot == root then
		return
	end
	unbindRaceFolderWatchers()
	watchedRacesRoot = root
	raceFolderAddedConn = root.ChildAdded:Connect(function()
		task.defer(refreshRaceNamesFromWorkspace)
	end)
	raceFolderRemovedConn = root.ChildRemoved:Connect(function()
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

local function displayNameForRaceId(id)
	if type(id) ~= "string" then
		return tostring(id)
	end
	local raw = raceDisplayNames[id]
	if type(raw) == "string" and raw ~= "" then
		return raw
	end
	return id
end

local function buildRaceDropdownLists(raceIds)
	local labels = {}
	local labelToId = {}
	local used = {}
	for _, rid in ipairs(raceIds) do
		local base = displayNameForRaceId(rid)
		local label = base
		if used[label] then
			label = base .. " (" .. rid .. ")"
		end
		used[label] = true
		labelToId[label] = rid
		table.insert(labels, label)
	end
	return labels, labelToId
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

-- Returns the center position and radius of the QueueRegion for the selected race
local function getQueueRegionCenter()
	local rid = automationState.selectedRaceId
	if type(rid) ~= "string" or rid == "" then return nil, 0 end
	local raceFolder = Workspace:FindFirstChild("Races") and Workspace.Races:FindFirstChild(rid)
	if not raceFolder then return nil, 0 end
	local qr = raceFolder:FindFirstChild("QueueRegion")
	if qr and qr:IsA("BasePart") then
		-- QueueRegion is a Cylinder: Size = (height, diameter, diameter)
		local radius = math.max(qr.Size.Y, qr.Size.Z) / 2
		return qr.Position, radius
	end
	return nil, 0
end


local function raceStateIsRacing(race)
	if not race or not race.Folder then
		return false
	end
	local st = race.Folder:FindFirstChild("State")
	if not st or not st:IsA("StringValue") then
		return false
	end
	return string.lower(st.Value) == "racing"
end

local function getLocalPlayerVehicleSeat()
	local char = localPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		local car = seat:FindFirstAncestorWhichIsA("Model")
		if car then
			return car, seat
		end
	end
	return nil, nil
end

-- Teleports the player's car to the race queue circle on first toggle,
-- then only re-teleports if the car drifts outside the circle boundary.
local function tryAutoQueueWithPlayers()
	if not automationState.autoQueueWithPlayers then
		queuePlayersTeleportedOnce = false
		return
	end
	if not automationAllowed() then
		return
	end
	-- If already in a race or lobby, do nothing
	if raceStateIsRacing(ClientRace.ClientRace) or Races.GetRaceFromPlayer(localPlayer) then
		return
	end
	local now = os.clock()
	if now - lastWithPlayerQueueClock < 0.5 then
		return
	end
	lastWithPlayerQueueClock = now
	local qPos, radius = getQueueRegionCenter()
	if not qPos then return end
	local car, seat = getLocalPlayerVehicleSeat()
	if not car or not seat then return end

	-- Flat distance (XZ plane) from car to circle center
	local dx = seat.Position.X - qPos.X
	local dz = seat.Position.Z - qPos.Z
	local flatDist = math.sqrt(dx * dx + dz * dz)

	-- Only teleport if: first time, or car left the circle
	if queuePlayersTeleportedOnce and flatDist <= radius then
		return -- still inside circle, leave it alone
	end

	-- Teleport car to circle center
	local targetPos = qPos + Vector3.new(0, 4, 0)
	local pivot = car:GetPivot()
	local seatW = seat.CFrame
	local newSeat = CFrame.new(targetPos)
	local newPivot = newSeat * seatW:Inverse() * pivot
	pcall(function()
		car:PivotTo(newPivot)
	end)
	-- Zero velocity so it doesn't slide out
	for _, d in car:GetDescendants() do
		if d:IsA("BasePart") then
			d.AssemblyLinearVelocity = Vector3.zero
			d.AssemblyAngularVelocity = Vector3.zero
		end
	end
	queuePlayersTeleportedOnce = true
end

local function checkpointIndexFromInstanceName(name)
	if type(name) ~= "string" then
		return nil
	end
	local direct = tonumber(name)
	if direct then
		return direct
	end
	local a = string.match(name, "^Checkpoint[_]?(%d+)$")
	if a then
		return tonumber(a)
	end
	local b = string.match(name, "^CP(%d+)$")
	if b then
		return tonumber(b)
	end
	return nil
end

local function isFinishCheckpointName(name)
	if type(name) ~= "string" then return false end
	local low = string.lower(name)
	return low == "finish" or low == "finishline" or low == "finish_line" or low == "end" or low == "goal"
end

-- Returns the highest numbered checkpoint index in the race's Checkpoints folder
local function getMaxCheckpointIndex(holder)
	if not holder then return 0 end
	local maxN = 0
	for _, ch in holder:GetChildren() do
		local n = checkpointIndexFromInstanceName(ch.Name)
		if n and n > maxN then
			maxN = n
		end
	end
	return maxN
end

-- Returns the Finish checkpoint instance if it exists
local function findFinishCheckpointInstance(holder)
	if not holder then return nil end
	for _, ch in holder:GetChildren() do
		if isFinishCheckpointName(ch.Name) then
			return ch
		end
	end
	for _, ch in holder:GetDescendants() do
		if isFinishCheckpointName(ch.Name) then
			return ch
		end
	end
	return nil
end

local function findCheckpointInstanceForNext(race, entry)
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
	local function matchesNum(ch)
		return checkpointIndexFromInstanceName(ch.Name) == nextNum
	end
	for _, ch in holder:GetChildren() do
		if matchesNum(ch) then
			return ch
		end
	end
	for _, ch in holder:GetDescendants() do
		if matchesNum(ch) then
			return ch
		end
	end
	-- No numbered checkpoint found — check if we're at the last checkpoint and should go to Finish
	local maxN = getMaxCheckpointIndex(holder)
	if cur >= maxN and maxN > 0 then
		-- We've completed all numbered checkpoints; return the Finish checkpoint
		return findFinishCheckpointInstance(holder)
	end
	return nil
end

local function findCheckpointInstanceForCurrent(race, entry)
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
	local function matchesNum(ch)
		return checkpointIndexFromInstanceName(ch.Name) == cur
	end
	for _, ch in holder:GetChildren() do
		if matchesNum(ch) then
			return ch
		end
	end
	for _, ch in holder:GetDescendants() do
		if matchesNum(ch) then
			return ch
		end
	end
	return nil
end

local function checkpointTargetCFrameFromInstance(inst)
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	if inst:IsA("Model") then
		local ok, cf = pcall(function()
			return inst:GetBoundingBox()
		end)
		if ok and cf then
			return cf
		end
		return inst:GetPivot()
	end
	if inst:IsA("Folder") then
		local sum = Vector3.zero
		local n = 0
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				sum += d.Position
				n += 1
			end
		end
		if n == 0 then
			return nil
		end
		return CFrame.new(sum / n)
	end
	return nil
end

local function getCheckpointTargetCFrame(race, entry)
	local inst = findCheckpointInstanceForNext(race, entry)
	return checkpointTargetCFrameFromInstance(inst)
end

local function getCheckpointWorldPosition(race, entry)
	local cf = getCheckpointTargetCFrame(race, entry)
	return cf and cf.Position or nil
end

local function doSnapVehicleToCFrame(targetCf)
	local car, seat = getLocalPlayerVehicleSeat()
	if not car or not seat then
		return
	end
	local pivot = car:GetPivot()
	local seatW = seat.CFrame
	local yoff = type(Config.CheckpointSnapYOffset) == "number" and Config.CheckpointSnapYOffset or 3
	local center = targetCf.Position
	local flatLv = Vector3.new(targetCf.LookVector.X, 0, targetCf.LookVector.Z)
	if flatLv.Magnitude < 0.12 then
		flatLv = Vector3.new(0, 0, -1)
	else
		flatLv = flatLv.Unit
	end
	local pos = center + Vector3.new(0, yoff, 0)
	local aim = pos + flatLv * 10
	local targetSeat = CFrame.lookAt(pos, aim)
	local newPivot = targetSeat * seatW:Inverse() * pivot
	pcall(function()
		car:PivotTo(newPivot)
	end)
	if Config.ZeroVelocityAfterCheckpointSnap then
		for _, d in car:GetDescendants() do
			if d:IsA("BasePart") then
				d.AssemblyLinearVelocity = Vector3.zero
				d.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end
end

local function snapLocalVehicleToNextCheckpoint(race, entry)
	if Config.UseClientCheckpointSnap == false then
		return
	end
	local targetCf = getCheckpointTargetCFrame(race, entry)
	if targetCf then
		doSnapVehicleToCFrame(targetCf)
	end
end

local function snapLocalVehicleToCurrentCheckpoint(race, entry)
	if Config.UseClientCheckpointSnap == false then
		return
	end
	local inst = findCheckpointInstanceForCurrent(race, entry)
	local targetCf = checkpointTargetCFrameFromInstance(inst)
	if targetCf then
		doSnapVehicleToCFrame(targetCf)
	end
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
	return v
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
	local race, entry = racerEntryForLocalPlayer()
	if not race or not entry then
		return
	end
	if not raceStateIsRacing(race) then
		return
	end
	local car, seat = getLocalPlayerVehicleSeat()
	if not car or not seat then
		return
	end
	local now = os.clock()
	if now - lastTeleportClock < Config.TeleportCooldownSeconds then
		return
	end
	lastTeleportClock = now
	lastChainTeleportClock = now
	Network.FireServer("TeleportCheckpoint")
	task.defer(function()
		local r = ClientRace.ClientRace
		if not r then
			return
		end
		local e = r.Racers:FindFirstChild(localPlayer.Name)
		if e then
			snapLocalVehicleToNextCheckpoint(r, e)
		end
	end)
end

local function checkpointChainGapSeconds()
	local cd = type(Config.TeleportCooldownSeconds) == "number" and Config.TeleportCooldownSeconds or 0.5
	local rate = type(Config.TeleportEverySeconds) == "number" and Config.TeleportEverySeconds > 0
		and Config.TeleportEverySeconds
		or Config.TeleportChainInterval
	return math.max(cd, rate)
end

local function isNextCheckpointFinish(race, entry)
	if not race or not entry then return false end
	local folder = race.Folder
	if not folder then return false end
	local holder = folder:FindFirstChild("Checkpoints")
	if not holder then return false end
	local cur = tonumber(entry:GetAttribute("Checkpoint")) or 0
	local maxN = getMaxCheckpointIndex(holder)
	return cur >= maxN and maxN > 0 and findFinishCheckpointInstance(holder) ~= nil
end

local function tryTeleportCheckpointChain()
	local race, entry = racerEntryForLocalPlayer()
	if not race or not entry then
		chainFinishWaitUntil = nil
		return
	end
	if not raceStateIsRacing(race) then
		lastChainTeleportClock = -1e9
		chainFinishWaitUntil = nil
		return
	end
	local car, seat = getLocalPlayerVehicleSeat()
	if not car or not seat then
		return
	end
	local now = os.clock()

	-- Check if the NEXT teleport would be to the Finish line
	if isNextCheckpointFinish(race, entry) then
		if automationState.waitBeforeFinish then
			-- Start the wait timer if not already waiting
			if not chainFinishWaitUntil then
				chainFinishWaitUntil = now + automationState.finishWaitTime
			end
			-- Don't teleport until the wait is over
			if now < chainFinishWaitUntil then
				return
			end
		end
		chainFinishWaitUntil = nil
	else
		chainFinishWaitUntil = nil
	end

	local gap = checkpointChainGapSeconds()
	if gap > 0 and (now - lastChainTeleportClock) < gap then
		return
	end
	lastChainTeleportClock = now
	lastTeleportClock = now
	Network.FireServer("TeleportCheckpoint")
	task.defer(function()
		local r = ClientRace.ClientRace
		if not r then
			return
		end
		local e = r.Racers:FindFirstChild(localPlayer.Name)
		if e then
			snapLocalVehicleToNextCheckpoint(r, e)
		end
	end)
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
	if not raceStateIsRacing(race) then
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

local function restoreCarNoclipBaselines()
	for p, was in noclipBaselineByPart do
		if p and p.Parent then
			p.CanCollide = was
		end
	end
	table.clear(noclipBaselineByPart)
	noclipBoundCar = nil
end

local function carNoclipWantActive()
	if not automationAllowed() then
		return false
	end
	if automationState.carNoclip then
		return true
	end
	if automationState.autoNoclipWhileRacing then
		local race = ClientRace.ClientRace
		return race ~= nil and raceStateIsRacing(race)
	end
	return false
end

local function stepCarNoclip()
	if not carNoclipWantActive() then
		restoreCarNoclipBaselines()
		return
	end
	local car = select(1, getLocalPlayerVehicleSeat())
	if not car then
		restoreCarNoclipBaselines()
		return
	end
	if noclipBoundCar and noclipBoundCar ~= car then
		restoreCarNoclipBaselines()
	end
	noclipBoundCar = car
	for _, d in car:GetDescendants() do
		if d:IsA("BasePart") then
			if noclipBaselineByPart[d] == nil then
				noclipBaselineByPart[d] = d.CanCollide
			end
			d.CanCollide = false
		end
	end
end

local function runCarFlyStep(dt)
	local car, seat = getLocalPlayerVehicleSeat()
	if not car or not seat then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local lv = cam.CFrame.LookVector
	local flat = Vector3.new(lv.X, 0, lv.Z)
	if flat.Magnitude > 1e-3 then
		flat = flat.Unit
	else
		flat = Vector3.new(0, 0, -1)
	end
	local move = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		move += flat
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		move -= flat
	end
	local right = flat:Cross(Vector3.yAxis)
	if right.Magnitude > 1e-3 then
		right = right.Unit
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			move += right
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			move -= right
		end
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		move += Vector3.yAxis
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
		move -= Vector3.yAxis
	end
	local baseFly = type(Config.CarFlySpeed) == "number" and Config.CarFlySpeed or 160
	local cap = baseFly * speedMultiplier
	local vmax = type(Config.CarFlyVelocityCap) == "number" and Config.CarFlyVelocityCap or 8000
	cap = math.clamp(cap, Config.CarFlySpeedMin or 20, vmax)
	if move.Magnitude > 1e-4 then
		seat.AssemblyLinearVelocity = move.Unit * cap
	else
		local v = seat.AssemblyLinearVelocity
		local damp = math.clamp(1 - dt * 4, 0, 1)
		seat.AssemblyLinearVelocity = Vector3.new(v.X * damp, v.Y * damp * 0.96, v.Z * damp)
	end
end

local function runCheckpointGuidedFlyStep()
	local race, entry = racerEntryForLocalPlayer()
	if not race or not entry or not raceStateIsRacing(race) then
		return
	end
	local car, seat = getLocalPlayerVehicleSeat()
	if not car or not seat then
		return
	end
	local target = getCheckpointWorldPosition(race, entry)
	if not target then
		return
	end
	local flat = Vector3.new(target.X - seat.Position.X, 0, target.Z - seat.Position.Z)
	local dy = target.Y - seat.Position.Y
	if flat.Magnitude < 8 then
		local v = seat.AssemblyLinearVelocity
		seat.AssemblyLinearVelocity = Vector3.new(v.X * 0.88, v.Y * 0.88, v.Z * 0.88)
		return
	end
	local hori = flat.Unit
	local yfac = math.clamp(dy * 0.06, -0.85, 0.85)
	local move = hori + Vector3.new(0, yfac, 0)
	if move.Magnitude < 1e-4 then
		return
	end
	move = move.Unit
	local baseFly = type(Config.CarFlySpeed) == "number" and Config.CarFlySpeed or 160
	local vmax = type(Config.CarFlyVelocityCap) == "number" and Config.CarFlyVelocityCap or 8000
	local cap = math.clamp(baseFly * speedMultiplier, Config.CarFlySpeedMin or 20, vmax)
	seat.AssemblyLinearVelocity = move * cap
end

local function holdCheckpointSnapIfChaining()
	if not automationAllowed() then
		return
	end
	if not (automationState.teleportChain or automationState.autoFarm) then
		return
	end
	local race, entry = racerEntryForLocalPlayer()
	if not race or not entry or not raceStateIsRacing(race) then
		return
	end
	local gap = checkpointChainGapSeconds()
	if gap <= 0 then
		return
	end
	
	if chainFinishWaitUntil ~= nil then
		snapLocalVehicleToCurrentCheckpoint(race, entry)
	elseif os.clock() - lastChainTeleportClock < gap then
		snapLocalVehicleToNextCheckpoint(race, entry)
	end
end

local function kpopDestroyMainWindowDeferred(win)
	if not win then
		return
	end
	task.defer(function()
		local items = win.Items
		local mf = items and items["MainFrame"]
		local inst = mf and mf.Instance
		if inst then
			local sg = inst:FindFirstAncestorWhichIsA("ScreenGui")
			if sg then
				sg:Destroy()
			elseif inst.Parent then
				inst:Destroy()
			end
		end
	end)
end

local function kpopPerformUnload()
	if not kpopScriptActive then
		return
	end
	kpopScriptActive = false
	if scriptInputConn then
		scriptInputConn:Disconnect()
		scriptInputConn = nil
	end
	if scriptRenderConn then
		scriptRenderConn:Disconnect()
		scriptRenderConn = nil
	end
	if scriptCharacterAddedConn then
		scriptCharacterAddedConn:Disconnect()
		scriptCharacterAddedConn = nil
	end
	if scriptWorkspaceRacesConn then
		scriptWorkspaceRacesConn:Disconnect()
		scriptWorkspaceRacesConn = nil
	end
	if scriptIdledConn then
		scriptIdledConn:Disconnect()
		scriptIdledConn = nil
	end
	unbindRaceFolderWatchers()
	disconnectAllCharacterSignals()
	restoreCarNoclipBaselines()
	clearVehicleTuneBinding()
	releaseAllVirtualKeys()
	local win = mainWindow
	mainWindow = nil
	table.clear(labels)
	kpopDestroyMainWindowDeferred(win)
	local ge = getge()
	ge.KpopDemonStarted = nil
	ge.KpopDemonUnload = nil
end

function KpopDemon.Unload()
	task.defer(kpopPerformUnload)
end

local function buildLibraryUi()
	Library.Theme["Accent"] = Color3.fromRGB(255, 105, 180)
	Library.Theme["AccentGradient"] = Color3.fromRGB(255, 140, 200)

	local Window = Library:Window({
		Name = "kpop demon",
		SubName = "Midnight Chasers",
		Logo = "120959262762131",
	})

	local function syncLibFlag(flag, value)
		local sf = Library.SetFlags
		if sf and sf[flag] then
			sf[flag](value)
		end
	end

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
	local raceLabels, raceLabelToId = buildRaceDropdownLists(raceIds)
	local defaultLabel = raceLabels[1]
	for i, id in ipairs(raceIds) do
		if id == defaultRace then
			defaultLabel = raceLabels[i]
			break
		end
	end

	Window:Category("Overview")
	local Overview = Window:Page({
		Name = "Status",
		Icon = "123944728972740",
	})
	local Live = Overview:Section({
		Name = "Controls",
		Description = "Script options",
		Icon = "138827881557940",
		Side = 1,
	})
	Live:Button({
		Name = "Unload script",
		Callback = function()
			KpopDemon.Unload()
		end,
	})

	Window:Category("Farm")
	local Farm = Window:Page({
		Name = "Farm",
		Icon = "108839695397679",
	})
	local SoloSec = Farm:Section({
		Name = "Solo Race",
		Description = "Select and queue for solo races",
		Icon = "126497581491926",
		Side = 1,
	})
	SoloSec:Dropdown({
		Name = "Race to run",
		Flag = "KpopRacePick",
		Default = defaultLabel,
		Items = raceLabels,
		Multi = false,
		Callback = function(v)
			local rid
			if type(v) == "string" then
				rid = raceLabelToId[v]
			elseif type(v) == "table" and v[1] then
				rid = raceLabelToId[v[1]]
			end
			if rid then
				automationState.selectedRaceId = rid
			end
		end,
	})
	SoloSec:Toggle({
		Name = "Auto Queue Solo",
		Flag = "KpopAutoSolo",
		Default = false,
		Callback = function(v)
			automationState.autoQueueSolo = v
		end,
	})
	SoloSec:Toggle({
		Name = "Auto Queue with Players",
		Flag = "KpopAutoQueuePlayers",
		Default = false,
		Callback = function(v)
			automationState.autoQueueWithPlayers = v
		end,
	})


	local AntiAfkSec = Farm:Section({
		Name = "Anti AFK",
		Description = "Bypasses 20 minute idle disconnect",
		Icon = "126497581491926",
		Side = 1,
	})
	AntiAfkSec:Toggle({
		Name = "Anti AFK",
		Flag = "KpopAntiAfk",
		Default = false,
		Callback = function(v)
			automationState.antiAfk = v
		end,
	})

	local CpSec = Farm:Section({
		Name = "Checkpoint Route",
		Description = "Teleports through checkpoints while racing",
		Icon = "103180437044643",
		Side = 1,
	})
	CpSec:Toggle({
		Name = "Auto Teleport to Checkpoints",
		Flag = "KpopTpChain",
		Default = false,
		Callback = function(v)
			automationState.teleportChain = v
		end,
	})
	CpSec:Toggle({
		Name = "Wait Before Finish Line",
		Flag = "KpopWaitFinish",
		Default = true,
		Callback = function(v)
			automationState.waitBeforeFinish = v
		end,
	})
	CpSec:Slider({
		Name = "Finish Wait Time",
		Flag = "KpopFinishWait",
		Min = 0,
		Max = 300,
		Default = 120,
		Decimals = 0,
		Suffix = "s",
		Callback = function(v)
			automationState.finishWaitTime = v
		end,
	})
	Window:Category("Modifications")
	local ModsPage = Window:Page({
		Name = "Mods",
		Icon = "108839695397679",
	})
	
	local TuneSec = ModsPage:Section({
		Name = "Car Tuning",
		Description = "Modify car performance",
		Side = 1,
	})
	TuneSec:Toggle({
		Name = "Apply Performance Mods",
		Flag = "KpopApplyMods",
		Default = false,
		Callback = function(v)
			Config.ApplySpeedMultiplierToChassisTune = v
			Config.ApplySteeringTune = v
			reapplyVehicleTune()
		end,
	})
	TuneSec:Slider({
		Name = "Top Speed Multiplier",
		Flag = "KpopSpeedMult",
		Min = 0.1,
		Max = 50,
		Default = speedMultiplier,
		Decimals = 2,
		Suffix = "x",
		Callback = function(v)
			setSpeedMultiplier(v)
		end,
	})
	TuneSec:Slider({
		Name = "Steering Multiplier",
		Flag = "KpopSteerMult",
		Min = 0.1,
		Max = 5,
		Default = steeringSensitivity,
		Decimals = 2,
		Suffix = "x",
		Callback = function(v)
			setSteeringSensitivity(v)
		end,
	})

	local WorldSec = ModsPage:Section({
		Name = "World Options",
		Description = "Adjust world traffic and physics",
		Side = 1,
	})
	WorldSec:Toggle({
		Name = "Disable Traffic",
		Flag = "KpopDisableTraffic",
		Default = false,
		Callback = function(v)
			automationState.disableTraffic = v
		end,
	})
	WorldSec:Toggle({
		Name = "Disable Car Collisions",
		Flag = "KpopDisableCollisions",
		Default = false,
		Callback = function(v)
			automationState.carNoclip = v
		end,
	})

	Window:Category("Movement")
	local MovePage = Window:Page({
		Name = "Physics",
		Icon = "138827881557940",
	})
	local CollideSec = MovePage:Section({
		Name = "Car collision",
		Description = "auto noclip only while phase Racing; restores when you leave the car",
		Icon = "126497581491926",
		Side = 1,
	})

	CollideSec:Toggle({
		Name = "Auto car noclip while Racing",
		Flag = "KpopAutoRaceNoclip",
		Default = true,
		Callback = function(v)
			automationState.autoNoclipWhileRacing = v
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
	kpopScriptActive = true
	mergeStaticRaceNames()
	refreshRaceNamesFromWorkspace()
	bindWorkspaceRacesWatcher()
	if not Workspace:FindFirstChild("Races") then
		scriptWorkspaceRacesConn = Workspace.ChildAdded:Connect(function(ch)
			if ch.Name == "Races" then
				refreshRaceNamesFromWorkspace()
				bindWorkspaceRacesWatcher()
			end
		end)
	end

	lastTeleportClock = -Config.TeleportCooldownSeconds
	lastChainTeleportClock = -1e9

	mainWindow = buildLibraryUi()

	scriptInputConn = UserInputService.InputBegan:Connect(function(input, processed)
		if not kpopScriptActive then
			return
		end
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

	local function onCharacterAdded(character)
		if not kpopScriptActive then
			return
		end
		disconnectAllCharacterSignals()
		restoreCarNoclipBaselines()
		clearVehicleTuneBinding()
		local hum = character:WaitForChild("Humanoid", 30)
		if not hum then
			return
		end
		local function handleSeat()
			task.defer(function()
				if not kpopScriptActive then
					return
				end
				local seat = hum.SeatPart
				if seat and seat:IsA("VehicleSeat") then
					local car = seat:FindFirstAncestorWhichIsA("Model")
					if car then
						bindVehicleTuneForSeat(car)
					end
				else
					clearVehicleTuneBinding()
					restoreCarNoclipBaselines()
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
	scriptCharacterAddedConn = localPlayer.CharacterAdded:Connect(onCharacterAdded)

	task.spawn(function()
		while kpopScriptActive do
			task.wait(0.2)
			if not kpopScriptActive then
				break
			end
			if automationAllowed() then
				if automationState.autoQueueSolo then
					tryAutoSoloQueue()
				end
				if automationState.autoQueueWithPlayers then
					tryAutoQueueWithPlayers()
				end
				if automationState.teleportChain or automationState.autoFarm then
					tryTeleportCheckpointChain()
				end
			end
		end
	end)

	scriptIdledConn = localPlayer.Idled:Connect(function()
		if not kpopScriptActive then
			return
		end
		if automationState.antiAfk then
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new(0, 0))
		end
	end)

	task.spawn(function()
		local iv = (type(Config.TuneReapplyIntervalSeconds) == "number" and Config.TuneReapplyIntervalSeconds > 0)
				and Config.TuneReapplyIntervalSeconds
			or 0.12
		while kpopScriptActive do
			task.wait(iv)
			if not kpopScriptActive then
				break
			end
			if automationAllowed() and lastTuneScript then
				if Config.ApplySpeedMultiplierToChassisTune or Config.ApplySteeringTune then
					local _, seat = getLocalPlayerVehicleSeat()
					if seat then
						reapplyVehicleTune()
					end
				end
			end
		end
	end)

	scriptRenderConn = RunService.RenderStepped:Connect(function(dt)
		if not kpopScriptActive then
			return
		end
		if automationState.disableTraffic then
			local npcs = Workspace:FindFirstChild("NPCVehicles")
			if npcs then
				local vehicles = npcs:FindFirstChild("Vehicles")
				if vehicles then
					vehicles:ClearAllChildren()
				end
			end
		end
		stepCarNoclip()
		holdCheckpointSnapIfChaining()
	end)
	getge().KpopDemonUnload = KpopDemon.Unload
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