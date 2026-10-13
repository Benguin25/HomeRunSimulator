--!nocheck
-- Runs the pitching tests outside Roblox with Lune (https://lune-org.github.io).
--
--   lune run tools/run-tests.luau
--
-- Mounts src/ as a minimal fake instance tree mirroring default.project.json
-- (ReplicatedStorage.Shared, ServerScriptService.Server) so modules can use
-- `script.Parent.X`, `game:GetService(...)` and `WaitForChild` unchanged.
-- Vector3/CFrame come from @lune/roblox (single precision, like Roblox).
-- Tests registered with `robloxTest` need real Instances and are skipped.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Node = {}

local function newNode(name: string, className: string, parent, file: string?)
	local node = {
		__name = name,
		__className = className,
		__parent = parent,
		__children = {},
		__file = file,
	}
	return setmetatable(node, Node)
end

Node.__index = function(self, key)
	if key == "Name" then
		return rawget(self, "__name")
	elseif key == "Parent" then
		return rawget(self, "__parent")
	elseif key == "ClassName" then
		return rawget(self, "__className")
	end
	local method = rawget(Node, key)
	if method then
		return method
	end
	local child = rawget(self, "__children")[key]
	if child then
		return child
	end
	error(`{key} is not a valid member of {rawget(self, "__name")}`, 2)
end

function Node.GetChildren(self)
	local list = {}
	for _, child in rawget(self, "__children") do
		table.insert(list, child)
	end
	return list
end

function Node.FindFirstChild(self, name)
	return rawget(self, "__children")[name]
end

function Node.WaitForChild(self, name)
	local child = rawget(self, "__children")[name]
	assert(child, `WaitForChild: {name} not found under {rawget(self, "__name")} (would yield forever)`)
	return child
end

function Node.GetService(self, name)
	return Node.WaitForChild(self, name)
end

function Node.IsA(self, className)
	return rawget(self, "__className") == className
end

local function mount(dir: string, name: string, parent)
	local initPath = `{dir}/init.luau`
	local node = newNode(
		name,
		if fs.isFile(initPath) then "ModuleScript" else "Folder",
		parent,
		if fs.isFile(initPath) then initPath else nil
	)
	for _, entry in fs.readDir(dir) do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			rawget(node, "__children")[entry] = mount(path, entry, node)
		elseif entry ~= "init.luau" and string.sub(entry, -5) == ".luau" then
			local base = string.sub(entry, 1, -6)
			-- Scripts (.server/.client) don't run here; their folders still mount.
			if string.sub(base, -7) ~= ".server" and string.sub(base, -7) ~= ".client" then
				rawget(node, "__children")[base] = newNode(base, "ModuleScript", node, path)
			end
		end
	end
	return node
end

local game = newNode("game", "DataModel", nil)
local replicatedStorage = newNode("ReplicatedStorage", "ReplicatedStorage", game)
local serverScriptService = newNode("ServerScriptService", "ServerScriptService", game)
rawget(game, "__children").ReplicatedStorage = replicatedStorage
rawget(game, "__children").ServerScriptService = serverScriptService
rawget(replicatedStorage, "__children").Shared = mount("src/shared", "Shared", replicatedStorage)
rawget(serverScriptService, "__children").Server = mount("src/server", "Server", serverScriptService)

local cache = {}
local loading = {}

local function requireNode(node)
	if cache[node] ~= nil then
		return cache[node]
	end
	local file = rawget(node, "__file")
	assert(file, `require: {rawget(node, "__name")} is not a ModuleScript`)
	assert(not loading[node], `require: cyclic dependency at {file}`)
	loading[node] = true
	-- selene: allow(global_usage)
	local env = setmetatable({
		script = node,
		require = requireNode,
		game = game,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
	}, { __index = _G }) -- Required to inherit the sandboxed Lune builtins.
	local chunk = luau.load(fs.readFile(file), { debugName = file, environment = env })
	local result = chunk()
	loading[node] = nil
	cache[node] = result
	return result
end

local testNode = rawget(rawget(serverScriptService, "__children").Server, "__children").Tests
if
	process.args[1] == "--balance"
	or process.args[1] == "--economy"
	or process.args[1] == "--worlds"
	or process.args[1] == "--rebirths"
	or process.args[1] == "--rebirths-baseline"
then
	local analysis = requireNode(
		if process.args[1] == "--rebirths" or process.args[1] == "--rebirths-baseline"
			then testNode.RebirthAnalysis
			elseif process.args[1] == "--worlds" then testNode.WorldProgressionAnalysis
			elseif process.args[1] == "--economy" then testNode.ProgressionAnalysis
			else testNode.BalanceAnalysis
	)
	local baselineStep = if process.args[1] == "--rebirths-baseline"
		then requireNode(replicatedStorage.Shared.Progression.ProgressionConfig).RebirthBalance.BaselineLevelsPerRebirth
		else nil
	local report = analysis.run(nil, baselineStep)
	local serde = require("@lune/serde")
	local json = serde.encode("json", report, true)
	if process.args[2] then
		fs.writeFile(process.args[2], json .. "\n")
	end
	print(json)
	process.exit(0)
end
if process.args[1] == "--spec" then
	local name = assert(process.args[2], "--spec requires a module name, e.g. ArcadeBalance.spec")
	local runner = requireNode(testNode.TestRunner)
	local summary = runner.run({ [name] = requireNode(testNode:WaitForChild(name)) }, false)
	process.exit(if summary.failed == 0 then 0 else 1)
end
local tests = requireNode(testNode)
local summary = tests.run(false)
process.exit(if summary.failed == 0 then 0 else 1)
