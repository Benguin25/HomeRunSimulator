--!strict
-- Identical measured contacts per level. Flat-field analytic sweeps are economy
-- benchmarks, never promises about the Studio stadium or estimates of real skill.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Progression.ProgressionConfig)
local Rules = require(Shared.Progression.ProgressionRules)
local Data = require(Shared.Progression.PlayerProgression)
local Ball = require(Shared.BattedBall.BattedBall)
local Field = require(Shared.BattedBall.FieldFrame)
local Landing = require(Shared.BattedBall.LandingDetector)
local BBTU = require(script.Parent.BattedBallTestUtil)
local Test = require(script.Parent.TestUtil)
local Contact = require(Shared.Batting.ContactQuality)
local Analysis = {}
local profiles: { [string]: { { number } } } = {
	Beginner = {
		{ 0.15, 0.025, -0.045 },
		{ -0.15, 0.015, 0.045 },
		{ 0, 0.035, 0.02 },
		{ 0.08, -0.015, -0.02 },
		{ 0, -0.03, 0.02 },
		{ 0, 0.13, 0 },
	},
	Average = {
		{ 0.08, -0.015, -0.02 },
		{ -0.08, -0.03, 0.02 },
		{ 0, -0.045, 0 },
		{ 0, 0.015, 0 },
		{ 0.15, -0.015, 0.045 },
		{ 0, -0.025, 0.01 },
	},
	Skilled = {
		{ 0, -0.035, 0 },
		{ 0.04, -0.045, 0.01 },
		{ -0.04, -0.055, -0.01 },
		{ 0, -0.025, 0 },
		{ 0, -0.045, 0 },
		{ 0.08, 0, 0.02 },
	},
}
type Sample = { contact: Contact.ContactResult?, frame: Field.Frame }
type Measurement = {
	coins: number,
	feet: number,
	seconds: number,
	exitMph: number,
	eligible: boolean,
	outcome: Landing.OutcomePayload?,
}
local function inputs(offsets: { { number } }): { Sample }
	local samples = {}
	for _, side in { "Right", "Left" } do
		BBTU.withBatterSide(side, function()
			local geometries = Test.geometries()
			for _, lane in { "straight", "rotated" } do
				local geometry = geometries[lane]
				for seed = 1, 3 do
					local pitch = BBTU.pitch(geometry, 500 + seed * 37)
					for _, offset in offsets do
						table.insert(samples, {
							contact = BBTU.swing(geometry, pitch, offset[1], offset[2], offset[3]).contact,
							frame = Field.new(geometry),
						})
					end
				end
			end
		end)
	end
	return samples
end
local function measure(sample: Sample, level: number): Measurement
	local contact = sample.contact
	if not contact then
		return { coins = 0, feet = 0, seconds = Config.Balance.BaseAttemptSeconds, exitMph = 0, eligible = false }
	end
	local launch = Ball.computeLaunch(
		sample.frame,
		contact,
		{ hitId = 1, laneId = "Test", pitchId = 1, userId = 1 },
		Rules.impactConfig(level)
	)
	launch.powerLevel = level
	local flight = Ball.buildFlight(sample.frame, launch)
	local outcome = Landing.toPayload(Landing.evaluate(flight, BBTU.scene(sample.frame, { BBTU.ground() }).caster))
	local coins, reason = Rules.reward(outcome)
	return {
		coins = coins,
		feet = if outcome.carryMeters then outcome.carryMeters / 0.3048 else 0,
		seconds = Config.Balance.BaseAttemptSeconds + outcome.endTime,
		exitMph = flight.exitSpeedMph,
		eligible = reason == "Fair carry",
		outcome = outcome,
	}
end
Analysis.profiles = profiles
Analysis.inputs = inputs
Analysis.measure = measure
function Analysis.run(): any
	local started = os.clock()
	local report: any = {
		configuration = Config,
		profiles = {},
		idealBenchmarks = {},
		stability = {},
		inputs = {
			sides = { "Right", "Left" },
			lanes = { "straight", "rotated" },
			pitchSeeds = { 537, 574, 611 },
			offsets = profiles,
		},
	}
	for name, offsets in profiles do
		local samples = inputs(offsets)
		local cache: { [number]: { [number]: Measurement } } = {}
		local function measurement(level: number, index: number): Measurement
			local bucket = cache[level]
			if not bucket then
				bucket = {}
				cache[level] = bucket
			end
			local m = bucket[index]
			if not m then
				m = measure(samples[index], level)
				bucket[index] = m
			end
			return m
		end
		local levels = {}
		local contactsPerGrid = 0
		for _, sample in samples do
			if sample.contact then
				contactsPerGrid += 1
			end
		end
		for _, level in Config.Balance.Levels do
			local coinSum, distanceSum, minCoins, maxCoins, best = 0, 0, math.huge, 0, 0
			for i, sample in samples do
				local m = measurement(level, i)
				if sample.contact then
					coinSum += m.coins
					distanceSum += m.feet
					minCoins, maxCoins = math.min(minCoins, m.coins), math.max(maxCoins, m.coins)
					best = math.max(best, m.feet)
				end
			end
			table.insert(levels, {
				level = level,
				multiplier = Rules.multiplier(level),
				nextCost = Rules.cost(level),
				meanCoinsPerContact = coinSum / contactsPerGrid,
				minCoins = minCoins,
				maxCoins = maxCoins,
				meanDistanceFeet = distanceSum / contactsPerGrid,
				bestFeet = best,
			})
		end
		local state = Data.new()
		local contacts, elapsed, previousPurchase, previousContact = 0, 0, 0, 0
		local purchases, milestones = {}, {}
		local session, at150 = nil, nil
		for attempt = 1, Config.Balance.MilestoneAttemptBudget do
			local index = (attempt - 1) % #samples + 1
			local m = measurement(state.powerLevel, index)
			elapsed += m.seconds
			if samples[index].contact then
				contacts += 1
				-- Economy state is fed the already measured authoritative benchmark.
				Data.launch(state, attempt)
				local measured = assert(m.outcome, "contact has measured benchmark outcome")
				Data.resolve(state, attempt, measured)
			end
			for _, feet in Config.Balance.MilestonesFeet do
				if m.eligible and m.feet >= feet and not milestones[tostring(feet)] then
					milestones[tostring(feet)] =
						{ attempts = attempt, contacts = contacts, seconds = elapsed, level = state.powerLevel }
				end
			end
			local cost = Rules.cost(state.powerLevel)
			if cost and state.coins >= cost then
				local result = Data.purchase(state, "Power", attempt, state.powerLevel, elapsed)
				assert(result.ok, "affordable benchmark purchase must succeed")
				table.insert(purchases, {
					level = state.powerLevel,
					attempt = attempt,
					contacts = contacts,
					attemptsSincePrevious = attempt - previousPurchase,
					contactsSincePrevious = contacts - previousContact,
					cost = cost,
				})
				previousPurchase, previousContact = attempt, contacts
			end
			if not session and elapsed >= Config.Balance.TypicalSessionSeconds then
				session = {
					attempts = attempt,
					contacts = contacts,
					seconds = elapsed,
					level = state.powerLevel,
					earnedCoins = state.earnedCoins,
				}
			end
			if attempt == Config.Balance.Attempts then
				at150 = {
					level = state.powerLevel,
					coins = state.coins,
					earnedCoins = state.earnedCoins,
					seconds = elapsed,
					contacts = contacts,
				}
			end
		end
		report.profiles[name] = {
			gridAttempts = #samples,
			gridContacts = contactsPerGrid,
			levels = levels,
			purchases = purchases,
			milestones = milestones,
			tenMinuteSession = session,
			after150Attempts = at150,
		}
	end
	local geometry = Test.geometries().straight
	local pitch = BBTU.pitch(geometry, 537)
	local frame = Field.new(geometry)
	local contact = assert(BBTU.swing(geometry, pitch, 0, -0.035, 0).contact, "ideal benchmark connects")
	for _, level in Config.Balance.Levels do
		local launch = Ball.computeLaunch(
			frame,
			contact,
			{ hitId = 1, laneId = "Test", pitchId = 1, userId = 1 },
			Rules.impactConfig(level)
		)
		launch.powerLevel = level
		local before = os.clock()
		local flight = Ball.buildFlight(frame, launch)
		local simMs = (os.clock() - before) * 1000
		before = os.clock()
		local outcome = Landing.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster)
		local sweepMs = (os.clock() - before) * 1000
		table.insert(report.idealBenchmarks, {
			level = level,
			exitMph = flight.exitSpeedMph,
			carryFeet = if outcome.carryMeters then outcome.carryMeters / 0.3048 else 0,
			endTime = outcome.endTime,
			steps = flight.trajectory.count - 1,
			casts = outcome.casts,
			simMs = simMs,
			sweepMs = sweepMs,
		})
	end
	-- Future-stadium benchmark only: same solver/launch, configurable thin air.
	local launch = Ball.computeLaunch(
		frame,
		contact,
		{ hitId = 1, laneId = "Test", pitchId = 1, userId = 1 },
		Rules.impactConfig(40)
	)
	local options =
		BBTU.flightConfig({ AirDensityScale = 0.05, MaxFlightSeconds = 30, MaxHorizontalDistanceMeters = 10000 })
	local future = Ball.buildFlight(frame, launch, options)
	report.stability.futureThinAir = {
		airDensityScale = 0.05,
		endReason = future.trajectory.endReason,
		trackedFeet = Ball.distanceAt(future, future.trajectory.duration) / 0.3048,
		steps = future.trajectory.count - 1,
		projectedCarryFeet = if future.fieldLanding then future.fieldLanding.distance / 0.3048 else nil,
	}
	report.elapsedSeconds = os.clock() - started
	return report
end
return Analysis
