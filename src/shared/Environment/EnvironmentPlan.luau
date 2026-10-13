--!strict
-- Builds the full Rookie environment as plain part specs (see EnvKit).
-- Deterministic for a given site and seed. Chunk order = realization order:
-- the stadium first (what the player sees on spawn), the distant world last.

local Config = require(script.Parent.EnvironmentConfig)
local Kit = require(script.Parent.EnvKit)
local Site = require(script.Parent.Site)
local Layout = require(script.Parent.Park.Layout)
local Field = require(script.Parent.Park.Field)
local Bowl = require(script.Parent.Park.Bowl)
local Outfield = require(script.Parent.Park.Outfield)
local Exterior = require(script.Parent.Park.Exterior)
local Town = require(script.Parent.World.Town)
local Landscape = require(script.Parent.World.Landscape)

local Plan = {}

export type Plan = {
	site: Site.Site,
	layout: Layout.Layout,
	chunks: { Kit.Chunk },
	count: number,
}

-- `yield` (optional) is called between steps so the client can spread plan
-- generation over several frames.
function Plan.build(plate: Vector3?, forward: Vector3?, yield: (() -> ())?): Plan
	local site = Site.new(plate, forward)
	local layout = Layout.new(site)
	local k = Kit.new(Config.Seed)
	k.yieldFn = yield
	Field.build(k, layout)
	Bowl.build(k, layout)
	k:step()
	Outfield.build(k, layout)
	k:step()
	Exterior.build(k, layout)
	k:step()
	Town.build(k, site)
	k:step()
	Landscape.build(k, site)
	local chunks = k:finish()
	return { site = site, layout = layout, chunks = chunks, count = k:count() }
end

return Plan
