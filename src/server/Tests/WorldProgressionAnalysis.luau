--!strict
-- Reuses Stage 6A's imperfect inputs; grounds are bounded analytic benchmarks.
-- Rookie's original stands/walls are Studio-only and absent from this benchmark.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local EconomyConfig = require(Shared.Progression.ProgressionConfig)
local Rules = require(Shared.Progression.ProgressionRules)
local Data = require(Shared.Progression.PlayerProgression)
local Ball = require(Shared.BattedBall.BattedBall)
local Landing = require(Shared.BattedBall.LandingDetector)
local Base = require(script.Parent.ProgressionAnalysis)
local BBTU = require(script.Parent.BattedBallTestUtil)
local Analysis = {}
function Analysis.run(): any
	local report: any = {
		requirementsFeet = {
			power = (Config.get("power") :: Config.Definition).requiredFeet,
			sky = (Config.get("sky") :: Config.Definition).requiredFeet,
		},
		profiles = {},
		ideal = {},
		assumptions = "Stage 6A input grids; bounded analytic ground, immediate affordable upgrades and travel after a completed hit. Rookie walls/stands excluded. Timings are CLI CPU, not server frame budgets.",
	}
	for name, offsets in Base.profiles do
		local samples = Base.inputs(offsets)
		local state = Data.new()
		local cache: { [string]: any } = {}
		local elapsed, contacts = 0, 0
		local unlocks: { [string]: any } = {}
		local started = os.clock()
		for attempt = 1, 1500 do
			local index = (attempt - 1) % #samples + 1
			local sample = samples[index]
			local worldId = state.worlds.currentWorld
			local key = `{worldId}/{state.powerLevel}/{index}`
			local measured = cache[key]
			if not measured then
				if sample.contact then
					local launch = Ball.computeLaunch(
						sample.frame,
						sample.contact,
						{ hitId = 1, laneId = "Benchmark", pitchId = 1, userId = 1 },
						Rules.impactConfig(state.powerLevel)
					)
					launch.powerLevel = state.powerLevel
					local flight = Ball.buildFlight(sample.frame, launch)
					local forward = (
						if worldId == "rookie" then Config.Rookie.ForwardStuds else Config.GroundForwardStuds
					) * sample.frame.metersPerStud
					local width = (if worldId == "rookie" then Config.Rookie.WidthStuds else Config.GroundWidthStuds)
						* sample.frame.metersPerStud
						/ 2
					local ground = BBTU.plane("BoundedGround", Vector3.zero, Vector3.yAxis, function(p)
						return p.X <= forward and p.X >= -100 and math.abs(p.Z) <= width
					end)
					local p = Landing.toPayload(Landing.evaluate(flight, BBTU.scene(sample.frame, { ground }).caster))
					measured = { outcome = p, seconds = EconomyConfig.Balance.BaseAttemptSeconds + p.endTime }
				else
					measured = { seconds = EconomyConfig.Balance.BaseAttemptSeconds }
				end
				cache[key] = measured
			end
			elapsed += measured.seconds
			if measured.outcome then
				contacts += 1
				Data.launch(state, attempt)
				Data.resolve(state, attempt, measured.outcome)
			end
			for _, world in Config.Worlds do
				if world.id ~= "rookie" and state.worlds.unlockedWorlds[world.id] and not unlocks[world.id] then
					unlocks[world.id] = {
						attempts = attempt,
						contacts = contacts,
						seconds = elapsed,
						level = state.powerLevel,
						bestFeet = state.worlds.qualifyingBestMeters / 0.3048,
					}
					Data.travel(
						state,
						world.id,
						attempt,
						state.worlds.currentWorld,
						elapsed,
						{ characterReady = true, hitBusy = false, returnReady = true, laneAvailable = true }
					)
				end
			end
			local cost = Rules.cost(state.powerLevel)
			if cost and state.coins >= cost then
				Data.purchase(state, "Power", attempt, state.powerLevel, elapsed)
			end
			if unlocks.sky then
				break
			end
		end
		report.profiles[name] = {
			unlocks = unlocks,
			cpuMs = (os.clock() - started) * 1000,
			coins = state.coins,
			earnedCoins = state.earnedCoins,
			level = state.powerLevel,
		}
	end
	local sample = Base.inputs({ { 0, -0.035, 0 } })[1]
	for _, level in { 0, 1, 2, 20, 21, 40 } do
		local start = os.clock()
		local m = Base.measure(sample, level)
		table.insert(report.ideal, {
			level = level,
			feet = m.feet,
			seconds = m.seconds - EconomyConfig.Balance.BaseAttemptSeconds,
			cpuMs = (os.clock() - start) * 1000,
		})
	end
	return report
end
return Analysis
