--!strict
-- End-to-end batted-ball tests from real swings against real pitches
-- (SwingResolver -> ContactResult -> ImpactModel -> flight). Nothing here uses
-- the quality label to produce a result; the label is only compared with the
-- physics afterwards.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PitchPhysics = require(Shared.Pitching.PitchPhysics)
local Units = require(Shared.Pitching.Units)
local SwingModel = require(Shared.Batting.SwingModel)
local BattedBall = require(Shared.BattedBall.BattedBall)
local BattedBallConfig = require(Shared.BattedBall.BattedBallConfig)
local FieldFrame = require(Shared.BattedBall.FieldFrame)

local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local CM = 0.01

local function projected(flight: BattedBall.Flight): number
	local landing = flight.fieldLanding
	return if landing then landing.distance else 0
end

local function rank(values: { number }): { number }
	local order = {}
	for i = 1, #values do
		order[i] = i
	end
	table.sort(order, function(a, b)
		return values[a] < values[b]
	end)
	local ranks = {}
	for position, index in order do
		ranks[index] = position
	end
	return ranks
end

local function spearman(a: { number }, b: { number }): number
	local ra, rb = rank(a), rank(b)
	local n = #a
	local sum = 0
	for i = 1, n do
		sum += (ra[i] - rb[i]) ^ 2
	end
	return 1 - 6 * sum / (n * (n * n - 1))
end

return function(t)
	-- Stage 1 arcade lift (BattedBallConfig.ArcadeContact.LiftDegrees): a
	-- squared-up hit flies at a home-run angle instead of a low line drive.
	t.test("squared-up contact is a hard, elevated drive up the middle", function()
		for laneName, geometry in TestUtil.geometries() do
			for seed = 1, 6 do
				local pitch = BBTU.pitch(geometry, seed * 13)
				local flight, contact, impact, frame = BBTU.hit(geometry, pitch, 0, 0, 0)
				TestUtil.assertTrue(flight.exitSpeedMph > 95 and flight.exitSpeedMph < 115, string.format("%s seed %d: EV %.1f mph", laneName, seed, flight.exitSpeedMph))
				TestUtil.assertTrue(flight.launchAngleDegrees > 15 and flight.launchAngleDegrees < 32, string.format("%s: launch %.1f", laneName, flight.launchAngleDegrees))
				TestUtil.assertTrue(math.abs(flight.sprayAngleDegrees) < 15, string.format("%s: spray %.1f", laneName, flight.sprayAngleDegrees))
				TestUtil.assertEqual(BattedBall.describeContact(frame, contact, impact), "Squared", `{laneName} seed {seed}: contact type`)
				TestUtil.assertTrue(impact.velocity.Magnitude > 0.85 * impact.idealExitSpeed, `{laneName}: squared-up EV near ideal`)
			end
		end
	end)

	t.test("under, centered and topped contact produce clearly different flights", function()
		for laneName, geometry in TestUtil.geometries() do
			local pitch = BBTU.pitch(geometry, 21)
			local under = BBTU.hit(geometry, pitch, 0, -3 * CM, 0)
			local center = BBTU.hit(geometry, pitch, 0, 0, 0)
			local topped = BBTU.hit(geometry, pitch, 0, 5 * CM, 0)
			TestUtil.assertTrue(under.launchAngleDegrees > center.launchAngleDegrees + 10, `{laneName}: under launches higher`)
			TestUtil.assertTrue(center.launchAngleDegrees > topped.launchAngleDegrees + 10, `{laneName}: topped launches lower`)
			TestUtil.assertTrue(topped.launchAngleDegrees < 0, `{laneName}: topped ball goes down`)
			TestUtil.assertTrue(under.backspinRpm > 1000, string.format("%s: under backspin %.0f rpm", laneName, under.backspinRpm))
			TestUtil.assertTrue(topped.backspinRpm < 0, string.format("%s: topped should have topspin (%.0f rpm)", laneName, topped.backspinRpm))
			TestUtil.assertTrue(under.apexHeightMeters > center.apexHeightMeters + 5, `{laneName}: fly ball apex`)
			-- Centered contact now carries farthest; under pops up, topped goes down.
			TestUtil.assertTrue(projected(center) > projected(under) and projected(under) > projected(topped), `{laneName}: carry ordering`)
			local deepUnder, c1, i1, frame = BBTU.hit(geometry, pitch, 0, -8 * CM, 0)
			TestUtil.assertEqual(BattedBall.describeContact(frame, c1, i1), "Under", `{laneName}: deep undercut type`)
			local _, c2, i2 = BBTU.hit(geometry, pitch, 0, 3 * CM, 0)
			TestUtil.assertEqual(BattedBall.describeContact(frame, c2, i2), "Topped", `{laneName}: topped type`)
			TestUtil.assertTrue(deepUnder.launchAngleDegrees > 50, `{laneName}: deep undercut is a pop-up`)
		end
	end)

	t.test("early contact is pulled and late contact goes the other way, for both batter sides", function()
		for _, side in { "Right", "Left" } do
			BBTU.withBatterSide(side, function()
				for laneName, geometry in TestUtil.geometries() do
					local pitch = BBTU.pitch(geometry, 33)
					local early = BBTU.hit(geometry, pitch, 0, -2 * CM, -0.02)
					local late = BBTU.hit(geometry, pitch, 0, -2 * CM, 0.02)
					local label = `{side}-handed {laneName}`
					TestUtil.assertEqual(early.frame.batterSide, side, `{label}: frame handedness`)
					TestUtil.assertTrue(early.pullAngleDegrees > 5, string.format("%s: early should be pulled (pull %+.1f)", label, early.pullAngleDegrees))
					TestUtil.assertTrue(late.pullAngleDegrees < -5, string.format("%s: late should go oppo (pull %+.1f)", label, late.pullAngleDegrees))
					-- Pull side is left field for a righty (spray < 0), right field for a lefty.
					local pullSign = if side == "Right" then -1 else 1
					TestUtil.assertTrue(early.sprayAngleDegrees * pullSign > 5, `{label}: early spray side`)
					TestUtil.assertTrue(late.sprayAngleDegrees * pullSign < -5, `{label}: late spray side`)
				end
			end)
		end
	end)

	t.test("stronger contact generally produces higher exit velocity", function()
		local geometry = TestUtil.geometries().straight
		local rng = TestUtil.rng(99)
		local scores, speeds = {}, {}
		local byLabel: { [string]: { number } } = { Perfect = {}, Great = {}, Good = {}, Weak = {} }
		for i = 1, 160 do
			local pitch = BBTU.pitch(geometry, 200 + i)
			local resolution = BBTU.swing(geometry, pitch, rng:NextNumber(-0.18, 0.12), rng:NextNumber(-0.07, 0.07), rng:NextNumber(-0.05, 0.05))
			local contact = resolution.contact
			if contact then
				local frame = FieldFrame.new(geometry)
				local launch = BattedBall.computeLaunch(frame, contact, { hitId = i, laneId = "Test", pitchId = i, userId = 1 })
				table.insert(scores, contact.score)
				table.insert(speeds, launch.velocity.Magnitude)
				table.insert(byLabel[contact.label], launch.velocity.Magnitude)
			end
		end
		TestUtil.assertTrue(#scores > 60, `only {#scores} contacts`)
		local rho = spearman(scores, speeds)
		TestUtil.assertTrue(rho > 0.5, string.format("rank correlation between contact quality and EV is %.2f", rho))
		local function mean(list: { number }): number
			local sum = 0
			for _, v in list do
				sum += v
			end
			return sum / math.max(1, #list)
		end
		TestUtil.assertTrue(mean(byLabel.Perfect) > mean(byLabel.Good) and mean(byLabel.Good) > mean(byLabel.Weak), "EV by label")
	end)

	t.test("the sweet spot beats the end of the bat and the handle", function()
		local geometry = TestUtil.geometries().straight
		local pitch = BBTU.pitch(geometry, 8)
		-- Moving the aim toward the batter puts the ball nearer the tip, and away from the batter nearer the handle.
		local across = -SwingModel.batterSideSign()
		local sweet, _, i0, frame = BBTU.hit(geometry, pitch, 0, -2 * CM, 0)
		local tip, c1, i1 = BBTU.hit(geometry, pitch, -across * 0.15, -2 * CM, 0)
		local handle, c2, i2 = BBTU.hit(geometry, pitch, across * 0.3, -2 * CM, 0)
		TestUtil.assertTrue(sweet.exitSpeedMph > tip.exitSpeedMph + 5, string.format("sweet %.1f vs tip %.1f mph", sweet.exitSpeedMph, tip.exitSpeedMph))
		TestUtil.assertTrue(sweet.exitSpeedMph > handle.exitSpeedMph + 15, string.format("sweet %.1f vs handle %.1f mph", sweet.exitSpeedMph, handle.exitSpeedMph))
		TestUtil.assertEqual(BattedBall.describeContact(frame, c1, i1), "Outside", "end of the bat")
		TestUtil.assertEqual(BattedBall.describeContact(frame, c2, i2), "Inside", "jammed")
		TestUtil.assertTrue(i0.restitution > i1.restitution and i0.restitution > i2.restitution, "restitution peaks at the sweet spot")
	end)

	t.test("glancing and very weak contact give weak, finite, short flights", function()
		local geometry = TestUtil.geometries().rotated
		local pitch = BBTU.pitch(geometry, 4)
		local perfect = BBTU.hit(geometry, pitch, 0, 0, 0)
		-- Ball just under the bottom edge of the barrel: a glancing foul tip / pop-up.
		local glancing, c, i, frame = BBTU.hit(geometry, pitch, 0, 8.5 * CM, 0)
		-- (0.75: the Stage 1 lift trades ~5 mph of a centered hit for launch
		-- angle, so the ratio to "perfect" rose from 0.65 to ~0.71; the
		-- glancing hit itself is still a steep, ~3 ft dribbler.)
		TestUtil.assertTrue(glancing.exitSpeedMph < 0.75 * perfect.exitSpeedMph, string.format("glancing EV %.1f mph", glancing.exitSpeedMph))
		TestUtil.assertTrue(glancing.launchAngleDegrees < -40, string.format("glancing launch %.1f", glancing.launchAngleDegrees))
		local kind = BattedBall.describeContact(frame, c, i)
		TestUtil.assertTrue(kind == "Glancing" or kind == "Weak" or kind == "Topped", `glancing type {kind}`)
		-- Jammed on the handle.
		local across = -SwingModel.batterSideSign()
		local jammed = BBTU.hit(geometry, pitch, across * 0.32, 0, 0.01)
		TestUtil.assertTrue(jammed.exitSpeedMph < 60, string.format("jammed EV %.1f mph", jammed.exitSpeedMph))
		for _, flight in { glancing, jammed } do
			TestUtil.assertTrue(projected(flight) < 45, "weak contact should not carry far")
			TestUtil.assertTrue(flight.trajectory.endReason == "Floor", "weak flights end on the floor")
			TestUtil.assertTrue(flight.exitSpeedMps == flight.exitSpeedMps, "finite")
		end
	end)

	t.test("beginner power reaches 350–400+ ft while original tuning remains recoverable", function()
		-- Gameplay acceptance for the configured beginner tier (Power.BatSpeedMultiplier),
		-- not a physical constant: the best elevated contacts can reach 350–400+ ft; this is a benchmark,
		-- not an assigned distance or a guarantee for typical swings.
		local geometry = TestUtil.geometries().straight
		local best = 0
		for seed = 1, 6 do
			local pitch = BBTU.pitch(geometry, 300 + seed)
			for _, dy in { -1, -2, -2.5, -3, -3.5, -4, -5 } do
				for _, dt in { -0.015, 0, 0.01 } do
					local resolution = BBTU.swing(geometry, pitch, 0, dy * CM, dt)
					local contact = resolution.contact
					if contact then
						local frame = FieldFrame.new(geometry)
						local launch = BattedBall.computeLaunch(frame, contact, { hitId = 1, laneId = "Test", pitchId = 1, userId = 1 })
						best = math.max(best, projected(BattedBall.buildFlight(frame, launch)))
					end
				end
			end
		end
		local feet = best / Units.METERS_PER_FOOT
		TestUtil.assertTrue(feet > 350 and feet < 430, string.format("best beginner carry %.0f ft", feet))
	end)

	t.test("simulator-scale power uses the same physics, scaled up", function()
		local geometry = TestUtil.geometries().straight
		local pitch = BBTU.pitch(geometry, 17)
		local base = BBTU.hit(geometry, pitch, 0, -3 * CM, 0)
		local power = BBTU.impactConfig({ ArcadePowerMultiplier = 4, MaxLaunchEnergyJoules = 1e6 })
		local thinAir = BBTU.flightConfig({ AirDensityScale = 0.3 })
		local big = BBTU.hit(geometry, pitch, 0, -3 * CM, 0, power, thinAir)
		TestUtil.assertNear(big.exitSpeedMps, base.exitSpeedMps * 4, 0.05, "4x exit speed")
		TestUtil.assertNear(big.launchAngleDegrees, base.launchAngleDegrees, 0.01, "same direction")
		local cfg = BattedBallConfig.Flight
		TestUtil.assertTrue(big.trajectory.count - 1 <= math.ceil(cfg.MaxFlightSeconds / cfg.FixedStepSeconds), "step budget")
		local landing = big.fieldLanding
		local farthest = if landing then landing.distance else big.trajectory.px[big.trajectory.count]
		TestUtil.assertTrue(farthest > 3 * projected(base), string.format("%.0f m vs base %.0f m", farthest, projected(base)))
		-- The default energy cap stops runaway multipliers.
		local capped = BBTU.hit(geometry, pitch, 0, -3 * CM, 0, BBTU.impactConfig({ ArcadePowerMultiplier = 50 }))
		local energy = 0.5 * 0.145 * capped.exitSpeedMps ^ 2
		TestUtil.assertTrue(energy <= BattedBallConfig.Power.MaxLaunchEnergyJoules * 1.001, "energy cap")
	end)

	t.test("the batted ball starts exactly where the pitch was at contact", function()
		for laneName, geometry in TestUtil.geometries() do
			local pitch = BBTU.pitch(geometry, 6)
			local flight, contact = BBTU.hit(geometry, pitch, 0, -2 * CM, 0.01)
			TestUtil.assertEqual(flight.launch.launchTime, contact.contactTime, `{laneName}: launch time`)
			local start = BattedBall.positionAt(flight, 0)
			TestUtil.assertTrue((start - contact.ballCenter).Magnitude < 1e-3, `{laneName}: start vs contact ball center`)
			local pitchAtContact = PitchPhysics.sample(pitch.trajectory, contact.contactTime - pitch.data.releaseTime)
			TestUtil.assertTrue((start - pitchAtContact).Magnitude < 1e-3, `{laneName}: start vs pitch position (no snap)`)
			-- And it moves off immediately in the launch direction.
			local soon = BattedBall.positionAt(flight, 1 / 240)
			local v = flight.launch.velocity
			local expected = FieldFrame.vectorToWorld(flight.frame, v.X, v.Y, v.Z) * flight.frame.studsPerMeter / 240
			TestUtil.assertTrue(((soon - start) - expected).Magnitude < 0.01, `{laneName}: initial direction`)
		end
	end)

	t.test("client prediction and server reconstruction agree bit for bit", function()
		local geometry = TestUtil.geometries().rotated
		local pitch = BBTU.pitch(geometry, 12)
		local resolution = BBTU.swing(geometry, pitch, 0.02, -0.025, -0.006)
		local contact = resolution.contact
		assert(contact, "no contact")
		TestUtil.assertTrue(contact.ballSpin == pitch.data.spin, "contact carries the pitch spin")
		local ids = { hitId = 7, laneId = "Test", pitchId = pitch.data.id, userId = 1 }
		local server = BattedBall.computeLaunch(FieldFrame.new(geometry), contact, ids)
		local client = BattedBall.computeLaunch(FieldFrame.new(geometry), contact, ids)
		TestUtil.assertTrue(server.velocity == client.velocity and server.spin == client.spin, "launch records differ")
		TestUtil.assertTrue(BattedBall.sameLaunch(server, client), "sameLaunch")
		local decoded = BattedBall.decode(BattedBall.encode(server, 3)) :: BattedBall.LaunchData
		local a = BattedBall.buildFlight(FieldFrame.new(geometry), server).trajectory
		local b = BattedBall.buildFlight(FieldFrame.new(geometry), decoded).trajectory
		TestUtil.assertEqual(a.count, b.count, "count")
		for i = 1, a.count, 7 do
			TestUtil.assertTrue(a.px[i] == b.px[i] and a.py[i] == b.py[i] and a.pz[i] == b.pz[i], `sample {i}`)
		end
	end)
end
