--!nocheck
-- Exports the Rookie environment plan as JSON for the optional offline preview
-- renderer (tools/environment-preview/render.py). Development aid only: it is
-- not Rojo-mapped and never runs in Roblox.
--
--   lune run tools/environment-preview/export.luau <out.json>
--
-- Uses the same minimal module loader as tools/run-tests.luau.

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


local Shared = replicatedStorage.Shared
local Plan = requireNode(Shared.Environment.EnvironmentPlan)
local started = os.clock()
local plan = Plan.build()
local elapsed = os.clock() - started

local parts, signs = {}, {}
local function vec(v)
	return { v.X, v.Y, v.Z }
end
for _, chunk in plan.chunks do
	for _, s in chunk.parts do
		local cf = s.cf
		local r, u, b = cf.RightVector, cf.UpVector, -cf.LookVector
		local p = cf.Position
		table.insert(parts, {
			s.shape, p.X, p.Y, p.Z,
			r.X, u.X, b.X, r.Y, u.Y, b.Y, r.Z, u.Z, b.Z,
			s.size.X, s.size.Y, s.size.Z, s.color[1], s.color[2], s.color[3], s.material, s.transparency,
		})
		if s.sign then
			local face = s.sign.face or "Front"
			local right, up, normal, depth
			if face == "Top" then
				right, up, normal, depth = cf.RightVector, cf.LookVector, cf.UpVector, s.size.Y / 2
			elseif face == "Back" then
				right, up, normal, depth = cf.RightVector, cf.UpVector, -cf.LookVector, s.size.Z / 2
			else
				right, up, normal, depth = -cf.RightVector, cf.UpVector, cf.LookVector, s.size.Z / 2
			end
			local w = if face == "Top" then s.size.X else s.size.X
			local h = if face == "Top" then s.size.Z else s.size.Y
			table.insert(signs, {
				p = vec(p + normal * (depth + 0.03)),
				r = { right.X, up.X, normal.X, right.Y, up.Y, normal.Y, right.Z, up.Z, normal.Z },
				w = w, h = h, text = s.sign.text, fg = s.sign.color,
				font = s.sign.font,
			})
		end
	end
end
local serde = require("@lune/serde")
local counts = {}
for _, chunk in plan.chunks do
	table.insert(counts, { name = chunk.name, parts = #chunk.parts, lod = chunk.lod })
end
fs.writeFile(process.args[1] or "environment.json", serde.encode("json", { parts = parts, signs = signs }))
print(serde.encode("json", { total = plan.count, buildSeconds = elapsed, chunks = counts }, true))
