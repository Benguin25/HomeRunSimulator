--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Data = require(Shared.Progression.PlayerProgression)
local Schema = require(Shared.Progression.PlayerData)
local Rules = require(Shared.Progression.ProgressionRules)
local Config = require(Shared.Progression.ProgressionConfig)
local Ball = require(Shared.BattedBall.BattedBall)
local Base = require(script.Parent.ProgressionAnalysis)
local Analysis = require(script.Parent.RebirthAnalysis)
local Stats = require(Shared.Gameplay.SessionStats)
local Test = require(script.Parent.TestUtil)
return function(t)
	t.test("imperfect skill profiles progress through three rebirth cycles without rapid farming", function()
		local report = Analysis.run(3)
		for _, profile in report.profiles do
			Test.assertEqual(#profile, 3)
			for _, cycle in profile do
				Test.assertTrue(cycle.completed)
				Test.assertTrue(cycle.attempts >= 20 and cycle.seconds > 120)
			end
			Test.assertTrue(profile[2].levelZeroMeanCoinsPerAttempt > profile[1].levelZeroMeanCoinsPerAttempt)
			Test.assertTrue(profile[3].levelZeroMeanCarryFeetPerContact > profile[1].levelZeroMeanCarryFeetPerContact)
		end
	end)
	t.test("rebirth atomically resets purchases and preserves permanent progression", function()
		local s = Data.new()
		s.powerLevel, s.coins, s.earnedCoins = assert(Rules.rebirthRequirement(0), "first requirement"), 1000, 2000
		s.worlds.currentWorld, s.worlds.unlockedWorlds.sky, s.worlds.qualifyingBestMeters = "sky", true, 600
		s.milestones["500"], s.lifetime.fairHits = true, 25
		Test.assertTrue(Data.rebirth(s, 1, 0, s.version, 1).ok)
		Test.assertEqual(s.coins, 0)
		Test.assertEqual(s.powerLevel, 0)
		Test.assertEqual(s.rebirths, 1)
		Test.assertEqual(s.earnedCoins, 2000)
		Test.assertEqual(s.worlds.currentWorld, "sky")
		local restored = Data.restore((assert((Schema.decode(Data.export(s))), "schema roundtrip")))
		Test.assertEqual(restored.rebirths, 1)
		Test.assertEqual(restored.worlds.qualifyingBestMeters, 600)
		Test.assertEqual(restored.lifetime.fairHits, 25)
		Test.assertTrue(restored.milestones["500"])
		Test.assertNear(Data.snapshot(restored).multiplier, 1.25, 1e-9)
	end)
	t.test("duplicate stale spam malformed and in-flight rebirths cannot reward", function()
		local s = Data.new()
		Test.assertEqual(Data.rebirth(s, 1, 0, 0, 1).reason, "InsufficientPower")
		s.powerLevel = 8
		Test.assertEqual(Data.rebirth(s, 1, 0, 0, 3).reason, "DuplicateRequest")
		Test.assertTrue(Data.rebirth(s, 2, 0, 0, 3).ok)
		s.powerLevel = assert(Rules.rebirthRequirement(1), "next requirement")
		Test.assertEqual(Data.rebirth(s, 3, 1, 1, 3.1).reason, "RateLimited")
		Test.assertEqual(Data.rebirth(s, 4, 0, 0, 5).reason, "StaleProgression")
		Data.launch(s, 1)
		Test.assertEqual(Data.rebirth(s, 5, 1, 1, 7).reason, "FinishHitFirst")
		for _, sequence in { -1, 0, 0.5, math.huge, 0 / 0, "forged" } :: { any } do
			Test.assertTrue(not Data.rebirth(s, sequence, 1, 1, 9).ok)
		end
		Test.assertEqual(s.rebirths, 1)
	end)
	t.test("all rebirth requirements remain achievable below the power cap", function()
		local s = Data.new()
		local previous = 0
		for count = 0, Config.Rebirth.MaxRebirths - 1 do
			local required = assert(Rules.rebirthRequirement(count), "cycle requirement")
			Test.assertTrue(required > previous and required <= Config.Power.MaxLevel)
			s.powerLevel, s.coins = required, 999
			Test.assertTrue(Data.rebirth(s, count + 1, count, s.version, count * 2).ok)
			previous = required
		end
		Test.assertEqual(Rules.rebirthRequirement(s.rebirths), nil)
		Test.assertEqual(Data.rebirth(s, 100, s.rebirths, s.version, 100).reason, "MaxRebirths")
	end)
	t.test("rebirth launch bonus applies once and captured wire flight remains deterministic", function()
		local sample = Base.inputs({ { 0, -0.035, 0 } })[1]
		local contact = assert(sample.contact, "benchmark contact")
		local base = Ball.computeLaunch(
			sample.frame,
			contact,
			{ hitId = 1, laneId = "Test", pitchId = 1, userId = 1 },
			Rules.impactConfig(0)
		)
		for _, count in { 1, 2, 6, 12 } do
			local launch = Ball.computeLaunch(
				sample.frame,
				contact,
				{ hitId = 1, laneId = "Test", pitchId = 1, userId = 1 },
				Rules.impactConfig(0, count)
			)
			launch.powerLevel, launch.rebirths = 0, count
			Test.assertNear(launch.velocity.Magnitude / base.velocity.Magnitude, Rules.permanentMultiplier(count), 1e-5)
			local copy = assert((Ball.decode(Ball.encode(launch, 5))), "wire roundtrip")
			Test.assertEqual(copy.rebirths, count)
			local flight, reconstructed = Ball.buildFlight(sample.frame, launch), Ball.buildFlight(sample.frame, copy)
			Test.assertNear(flight.trajectory.duration, reconstructed.trajectory.duration, 1e-12)
			Test.assertNear(flight.trajectory.px[10], reconstructed.trajectory.px[10], 1e-12)
			-- Building a later configuration never mutates captured velocity/spin.
			Rules.impactConfig(20, count)
			Test.assertTrue(Ball.sameLaunch(launch, copy))
		end
		Test.assertNear(Rules.multiplier(3, 2), Config.Power.Growth ^ 3 * 1.5, 1e-9)
	end)
	t.test("permanent records restore without contaminating session averages", function()
		local stats = Stats.new()
		Stats.restoreRecords(stats, 600, { ["500"] = true })
		local snapshot = Stats.snapshot(stats)
		Test.assertEqual(snapshot.longestMeters, 600)
		Test.assertEqual(snapshot.swings, 0)
		Test.assertEqual(snapshot.averageDistanceMeters, 0)
		Test.assertTrue(stats.reached[500])
	end)
end
