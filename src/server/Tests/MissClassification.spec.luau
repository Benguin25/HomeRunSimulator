--!strict
-- Miss reasons: timing mistakes must read as Early/Late, aim mistakes as
-- Over/Under/Inside/Outside, decided from the simulated swing and ball.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pitching = Shared:WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local Pitch = require(Pitching.Pitch)
local PitchPhysics = require(Pitching.PitchPhysics)
local Batting = Shared:WaitForChild("Batting")
local SwingModel = require(Batting.SwingModel)
local SwingResolver = require(Batting.SwingResolver)

local TestUtil = require(script.Parent.TestUtil)

local units = TestUtil.units
local CM = units.toStuds(0.01)
local EPOCH = 1.7e9

type Setup = {
	geometry: LaneGeometry.Geometry,
	flight: Pitch.Flight,
	ballX: number,
	ballY: number,
	ideal: number,
}

local function setup(geometry: LaneGeometry.Geometry, seed: number): Setup
	local release = EPOCH + 1
	local data = Pitch.generate(geometry, TestUtil.rng(seed), { id = seed, laneId = "Test", windupTime = release - 1, releaseTime = release })
	local flight = Pitch.buildFlight(geometry, data)
	local ideal = SwingResolver.idealContactTime(geometry, flight)
	assert(ideal, "no contact-plane crossing")
	local ball = PitchPhysics.sample(flight.trajectory, ideal - release)
	local offset = ball - SwingModel.contactPlane(geometry).point
	return { geometry = geometry, flight = flight, ballX = offset:Dot(geometry.right), ballY = offset:Dot(geometry.up), ideal = ideal }
end

-- Swing with the given errors: timing in ms (- = early), aim vertical in cm
-- (+ = aimed high), lateral in cm (+ = aim shifted toward the plate, i.e.
-- farther from the batter).
local function swingWith(s: Setup, timingMs: number, verticalCm: number, lateralCm: number): SwingModel.Swing
	local across = -SwingModel.batterSideSign()
	return SwingModel.new(
		s.geometry,
		s.ballX + across * lateralCm * CM,
		s.ballY + verticalCm * CM,
		SwingModel.startTimeForSquareAt(s.ideal + timingMs / 1000)
	)
end

local function resolve(s: Setup, timingMs: number, verticalCm: number, lateralCm: number): SwingResolver.Resolution
	return SwingResolver.resolve(s.geometry, s.flight, swingWith(s, timingMs, verticalCm, lateralCm))
end

local function expectMiss(label: string, r: SwingResolver.Resolution, reason: string)
	TestUtil.assertTrue(r.contact == nil, `{label}: expected a miss but the swing connected`)
	TestUtil.assertEqual(r.missReason, reason, label)
end

return function(t)
	t.test("pure timing mistakes are Early / Late, with the size of the mistake", function()
		for laneName, geometry in TestUtil.geometries() do
			local s = setup(geometry, 7)
			-- (Much later than ~100 ms the Active window starts after the ball is
			-- caught, which is NoOverlap / a practice swing, not a miss.)
			for _, ms in { 70, 90 } do
				local late = resolve(s, ms, 0, 0)
				expectMiss(`{laneName} {ms} ms late`, late, "Late")
				TestUtil.assertNear(late.missAmount :: number, ms / 1000, 1e-3, "late amount")
			end
			for _, ms in { 80, 100, 140 } do
				local early = resolve(s, -ms, 0, 0)
				expectMiss(`{laneName} {ms} ms early`, early, "Early")
				TestUtil.assertNear(early.missAmount :: number, ms / 1000, 1e-3, "early amount")
			end
		end
	end)

	t.test("pure aim mistakes with good timing are Over / Under / Inside / Outside", function()
		for laneName, geometry in TestUtil.geometries() do
			local s = setup(geometry, 7)
			expectMiss(`{laneName} aimed high`, resolve(s, 0, 16, 0), "Over")
			expectMiss(`{laneName} aimed low`, resolve(s, 0, -16, 0), "Under")
			expectMiss(`{laneName} small timing error, aimed high`, resolve(s, 15, 14, 0), "Over")
			expectMiss(`{laneName} small timing error, aimed low`, resolve(s, -15, -14, 0), "Under")
			-- Aim shifted toward the plate: the ball is closer to the batter than the bat's
			-- sweet spot. (Up to ~70 cm it still hits the handle; beyond the knob it is Inside.)
			expectMiss(`{laneName} aimed too far out`, resolve(s, 0, 0, 80), "Inside")
			expectMiss(`{laneName} aimed too far in`, resolve(s, 0, 0, -45), "Outside")
			local high = resolve(s, 0, 16, 0)
			TestUtil.assertNear(units.toMeters(high.missAmount :: number) * 100, 16, 0.6, "vertical miss amount in cm")
		end
	end)

	t.test("regression: an early/late swing with a small aim error reads as timing, not Over/Under", function()
		-- Playtest report: swings ~55 ms early were called "swung under/over it".
		-- The old rule blamed aim for anything within 60 ms of ideal timing.
		for laneName, geometry in TestUtil.geometries() do
			local s = setup(geometry, 7)
			expectMiss(`{laneName} early + a little low`, resolve(s, -55, -7, 0), "Early")
			expectMiss(`{laneName} late + a little high`, resolve(s, 55, 7, 0), "Late")
			expectMiss(`{laneName} early + a little high`, resolve(s, -80, 5, 0), "Early")
			-- And the other way round: nearly on time but well off vertically stays an aim miss.
			expectMiss(`{laneName} on time + low`, resolve(s, -20, -11, 0), "Under")
			expectMiss(`{laneName} on time + high`, resolve(s, 20, 11, 0), "Over")
		end
	end)

	t.test("swings that connect have no miss reason; swings off the pitch are NoOverlap", function()
		local s = setup(TestUtil.geometries().straight, 3)
		local hit = resolve(s, 0, 0, 0)
		TestUtil.assertTrue(hit.contact ~= nil and hit.missReason == nil and hit.missAmount == nil, "contact must not carry a miss reason")
		local release = s.flight.data.releaseTime
		local early = SwingResolver.resolve(s.geometry, s.flight, SwingModel.new(s.geometry, s.ballX, s.ballY, release - 2))
		TestUtil.assertEqual(early.missReason, "NoOverlap", "swing long before the pitch")
	end)

	t.test("every miss is explained by a mistake that, once fixed, really connects", function()
		local rng = TestUtil.rng(99)
		local seen: { [string]: number } = {}
		local checked = 0
		for _, geometry in TestUtil.geometries() do
			for seed = 1, 3 do
				local s = setup(geometry, seed * 17)
				for _ = 1, 40 do
					local timingMs = rng:NextNumber(-130, 130)
					local verticalCm = rng:NextNumber(-18, 18)
					local lateralCm = rng:NextNumber(-50, 50)
					local swing = swingWith(s, timingMs, verticalCm, lateralCm)
					local r = SwingResolver.resolve(geometry, s.flight, swing)
					if r.contact then
						TestUtil.assertTrue(r.missReason == nil, "contact with a miss reason")
						continue
					end
					local missReason = r.missReason
					assert(missReason, "miss without a reason")
					local reason: string = missReason
					if reason == "NoOverlap" then
						continue -- not a miss: the swing never met the pitch (a practice swing)
					end
					local analysis = r.missAnalysis
					assert(analysis, "miss without an analysis")
					seen[reason] = (seen[reason] or 0) + 1
					checked += 1

					-- Direction of the reason matches the signed error.
					local label = `{reason} (t {timingMs}, v {verticalCm}, l {lateralCm})`
					if reason == "Early" then
						TestUtil.assertTrue(analysis.timing < 0, `{label}: Early but timing error is {analysis.timing}`)
					elseif reason == "Late" then
						TestUtil.assertTrue(analysis.timing > 0, `{label}: Late but timing error is {analysis.timing}`)
					elseif reason == "Under" then
						TestUtil.assertTrue(analysis.vertical > 0, `{label}: Under but the ball is not above the aim`)
					elseif reason == "Over" then
						TestUtil.assertTrue(analysis.vertical < 0, `{label}: Over but the ball is not below the aim`)
					elseif reason == "Outside" then
						TestUtil.assertTrue(analysis.lateral > 0, `{label}: Outside but the ball is not farther out`)
					elseif reason == "Inside" then
						TestUtil.assertTrue(analysis.lateral < 0, `{label}: Inside but the ball is not closer in`)
					end

					-- The blamed mistake, fixed alone, really would have hit (when any single fix would).
					local anyFix = analysis.fixes.timing or analysis.fixes.vertical or analysis.fixes.lateral
					if anyFix then
						local axis = if reason == "Early" or reason == "Late" then "timing" elseif reason == "Over" or reason == "Under" then "vertical" else "lateral"
						TestUtil.assertTrue((analysis.fixes :: any)[axis], `{label}: blamed {axis} but fixing it alone does not connect`)
						local fixed = if axis == "timing"
							then SwingModel.new(geometry, swing.aimX, swing.aimY, SwingModel.startTimeForSquareAt(s.ideal))
							elseif axis == "vertical" then SwingModel.new(geometry, swing.aimX, s.ballY, swing.startTime)
							else SwingModel.new(geometry, s.ballX, swing.aimY, swing.startTime)
						TestUtil.assertTrue(SwingResolver.resolve(geometry, s.flight, fixed).contact ~= nil, `{label}: the fix does not connect`)
					end
				end
			end
		end
		TestUtil.assertTrue(checked > 100, `only {checked} misses checked`)
		for _, reason in { "Early", "Late", "Over", "Under", "Inside", "Outside" } do
			TestUtil.assertTrue((seen[reason] or 0) > 0, `no sample produced {reason}`)
		end
	end)
end
