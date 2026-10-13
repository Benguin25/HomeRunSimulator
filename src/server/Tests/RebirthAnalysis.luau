--!strict
-- Same Stage 6A imperfect contacts, measured sweeps and bounded Stage 6B fields.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Progression.ProgressionConfig)
local Worlds = require(Shared.Worlds.WorldConfig)
local Rules = require(Shared.Progression.ProgressionRules)
local Data = require(Shared.Progression.PlayerProgression)
local Ball = require(Shared.BattedBall.BattedBall)
local Landing = require(Shared.BattedBall.LandingDetector)
local Base = require(script.Parent.ProgressionAnalysis)
local BBTU = require(script.Parent.BattedBallTestUtil)
local Analysis = {}
function Analysis.measure(sample: any, level: number, rebirths: number, worldId: string): any
	if not sample.contact then
		return { seconds = Config.Balance.BaseAttemptSeconds, coins = 0, feet = 0, contact = false }
	end
	local launch = Ball.computeLaunch(
		sample.frame,
		sample.contact,
		{ hitId = 1, laneId = "Benchmark", pitchId = 1, userId = 1 },
		Rules.impactConfig(level, rebirths)
	)
	launch.powerLevel, launch.rebirths = level, rebirths
	local flight = Ball.buildFlight(sample.frame, launch)
	local forward = (if worldId == "rookie" then Worlds.Rookie.ForwardStuds else Worlds.GroundForwardStuds)
		* sample.frame.metersPerStud
	local width = (if worldId == "rookie" then Worlds.Rookie.WidthStuds else Worlds.GroundWidthStuds)
		* sample.frame.metersPerStud
		/ 2
	local ground = BBTU.plane("BoundedGround", Vector3.zero, Vector3.yAxis, function(p)
		return p.X <= forward and p.X >= -100 and math.abs(p.Z) <= width
	end)
	local p = Landing.toPayload(Landing.evaluate(flight, BBTU.scene(sample.frame, { ground }).caster))
	return {
		outcome = p,
		seconds = Config.Balance.BaseAttemptSeconds + p.endTime,
		coins = Rules.reward(p),
		feet = if p.carryMeters then p.carryMeters / 0.3048 else 0,
		contact = true,
		exitMph = flight.exitSpeedMph,
	}
end
function Analysis.run(cycles: number?, levelsPerRebirth: number?): any
	local tuning = table.clone(Config.Rebirth)
	tuning.LevelsPerRebirth = levelsPerRebirth or tuning.LevelsPerRebirth
	local report: any = {
		configuration = tuning,
		profiles = {},
		ideal = {},
		assumptions = "72-attempt Stage 6A imperfect grids, bounded Stage 6B grounds, Rookie walls excluded. Immediate upgrades/rebirths and travel after resolution. Fixed 3.5s overhead plus measured flight; not human wall-clock estimates. Maximum 20,000 attempts per cycle.",
	}
	for name, offsets in Base.profiles do
		local samples = Base.inputs(offsets)
		local cache: { [string]: any } = {}
		local function measure(level: number, rebirths: number, world: string, index: number): any
			local key = `{level}/{rebirths}/{world}/{index}`
			if not cache[key] then
				cache[key] = Analysis.measure(samples[index], level, rebirths, world)
			end
			return cache[key]
		end
		local state = Data.new()
		local attempt, elapsed, contacts, travelSequence = 0, 0, 0, 0
		local summaries = {}
		for count = 0, (cycles or Config.Rebirth.MaxRebirths) - 1 do
			local startAttempts, startContacts, startSeconds, startEarned =
				attempt, contacts, elapsed, state.earnedCoins
			local required = tuning.FirstLevel + tuning.LevelsPerRebirth * count
			local eligible = false
			for _ = 1, Config.RebirthBalance.AttemptsPerCycle do
				attempt += 1
				local index = (attempt - 1) % #samples + 1
				local m = measure(state.powerLevel, count, state.worlds.currentWorld, index)
				elapsed += m.seconds
				if m.contact then
					contacts += 1
					Data.launch(state, attempt)
					Data.resolve(state, attempt, m.outcome)
				end
				for _, world in Worlds.Worlds do
					if
						state.worlds.unlockedWorlds[world.id]
						and world.id ~= state.worlds.currentWorld
						and world.requiredFeet
							> (Worlds.get(state.worlds.currentWorld) :: Worlds.Definition).requiredFeet
					then
						travelSequence += 1
						Data.travel(
							state,
							world.id,
							travelSequence,
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
				if state.powerLevel >= required then
					eligible = true
					break
				end
			end
			local coinSum, feetSum, contactCount, exitSum = 0, 0, 0, 0
			-- Compare purchased level zero after each permanent bonus using identical inputs.
			for i = 1, #samples do
				local m = measure(0, count, state.worlds.currentWorld, i)
				coinSum += m.coins
				feetSum += m.feet
				if m.contact then
					contactCount += 1
					exitSum += m.exitMph
				end
			end
			table.insert(summaries, {
				rebirth = count + 1,
				requiredLevel = required,
				completed = eligible,
				attempts = attempt - startAttempts,
				contacts = contacts - startContacts,
				seconds = elapsed - startSeconds,
				coinsEarned = state.earnedCoins - startEarned,
				cumulativeAttempts = attempt,
				cumulativeSeconds = elapsed,
				permanentBefore = Rules.permanentMultiplier(count),
				permanentAfter = Rules.permanentMultiplier(count + 1),
				levelZeroMeanCoinsPerAttempt = coinSum / #samples,
				levelZeroMeanCarryFeetPerContact = feetSum / contactCount,
				levelZeroMeanExitMph = exitSum / contactCount,
				world = state.worlds.currentWorld,
				bestFeet = state.worlds.qualifyingBestMeters / 0.3048,
			})
			if not eligible then
				break
			end
			assert(Data.rebirth(state, count + 1, count, state.version, elapsed).ok, "benchmark rebirth succeeds")
		end
		report.profiles[name] = summaries
	end
	local ideal = Base.inputs({ { 0, -0.035, 0 } })[1]
	for count = 0, Config.Rebirth.MaxRebirths do
		local m = Analysis.measure(ideal, 0, count, "sky")
		table.insert(report.ideal, {
			rebirths = count,
			multiplier = Rules.permanentMultiplier(count),
			carryFeet = m.feet,
			coins = m.coins,
			exitMph = m.exitMph,
			seconds = m.seconds,
		})
	end
	return report
end
return Analysis
