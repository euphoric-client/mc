if not game:IsLoaded() then
	game.Loaded:Wait()
end

assert(type(getgenv) == "function", "kpop demon loader: getgenv required (executor)")
assert(type(loadstring) == "function", "kpop demon loader: loadstring required (executor)")

local g = getgenv()
local base = g.KpopDemonRawBase or "https://raw.githubusercontent.com/euphoric-client/mc/main/"
if string.sub(base, -1) ~= "/" then
	base = base .. "/"
end

local function fetch(rel)
	return game:HttpGet(base .. rel, true)
end

local function runModule(rel)
	local body = fetch(rel)
	local fn, err = loadstring(body, "@" .. rel)
	assert(fn, err)
	return fn()
end

g.KpopDemonConfig = runModule("core/KpopDemonConfig.lua")
g.KpopDemonHotkeys = runModule("menu/KpopDemonHotkeys.lua")
g.KpopDemonStarted = nil

local mainBody
local paths = { "module/kpop%20demon.lua", "module/kpop demon.lua" }
for i = 1, #paths do
	local ok, body = pcall(fetch, paths[i])
	if ok and type(body) == "string" and #body > 10 then
		mainBody = body
		break
	end
end
assert(mainBody, "kpop demon: could not fetch main script from git (check branch and file name)")

local fn, err = loadstring(mainBody, "@kpop demon")
assert(fn, err)
fn()
