--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Gate = require(Shared.Gameplay.ReturnGate)
local Config = require(Shared.Gameplay.GameplayConfig)
local Stats = require(Shared.Gameplay.SessionStats)
local Camera = require(Shared.Presentation.CameraDirector)
local CameraMath = require(Shared.Presentation.CameraMath)
local Presentation = require(Shared.Presentation.PresentationConfig)
local Lifecycle = require(Shared.BattedBall.HitLifecycle)
local BattedBall = require(Shared.BattedBall.BattedBall)
local Landing = require(Shared.BattedBall.LandingDetector)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local Pitch = require(Shared.Pitching.Pitch)
local PitchLane = require(Shared.Pitching.PitchLane)
local BBTU = require(script.Parent.BattedBallTestUtil)
local Test = require(script.Parent.TestUtil)

local function makeHit(id: number, now: number): Lifecycle.ActiveHit
	local frame = FieldFrame.new(Test.geometries().straight)
	local launch = BBTU.launchData(frame, { speedMph = 100, launchDegrees = 28, backspinRpm = 2000 })
	launch.hitId, launch.launchTime = id, now
	local flight = BattedBall.buildFlight(frame, launch)
	return {
		launch = launch,
		flight = flight,
		outcome = Landing.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster),
	}
end

return function(t)
	t.test("validated hit recovery resumes immediately without reviving a stopped lane", function()
		local geometry = Test.geometries().straight
		local lane = PitchLane.new("Test", {
			createPitch = function(_, id, windup, release)
				local data = Pitch.generate(
					geometry,
					Test.rng(10),
					{ id = id, laneId = "Test", windupTime = windup, releaseTime = release }
				)
				return { data = data, flight = Pitch.buildFlight(geometry, data) }
			end,
		}, { WindupSeconds = 1.6, ReadySeconds = 50, ResetSeconds = 50, FirstPitchDelaySeconds = 0 })
		lane:start(0, 0)
		lane:update(0)
		lane:abortPitch(2, "Contact")
		lane:setPaused(true)
		lane:update(3)
		Test.assertTrue(lane.pitch == nil, "old reset still pending")
		lane:resumeAfterHit(3)
		lane:update(3)
		Test.assertEqual(lane.pitchesStarted, 2, "new windup immediately")
		local active = lane.pitch
		lane:resumeAfterHit(3.1)
		Test.assertEqual(lane.pitch, active, "do not replace active pitch")
		lane:stop(4, "BatterDied")
		lane:resumeAfterHit(5)
		lane:update(1000)
		Test.assertEqual(lane.state, "Idle", "dead lane stays stopped")
	end)
	t.test("readiness authenticates owner, assignment, hit, character and elapsed return", function()
		local g = Gate.new(17, 4, 0)
		Test.assertTrue(not Gate.canPitch(g), "initial camera gate")
		local ok, reason = Gate.request(g, 17, 4, 0, "Ready", 0)
		Test.assertTrue(not ok and reason == "CharacterNotReady")
		Gate.character(g, true, 5)
		ok, reason = Gate.request(g, 17, 4, 0, "Ready", 1)
		Test.assertTrue(not ok and reason == "StaleAssignment")
		ok, reason = Gate.request(g, 999, 5, 0, "Ready", 2)
		Test.assertTrue(not ok and reason == "WrongOwner")
		ok = Gate.request(g, 17, 5, 0, "Ready", 3)
		Test.assertTrue(ok and Gate.canPitch(g), "initial readiness")
		Gate.begin(g, 8, 12)
		ok, reason = Gate.request(g, 17, 5, 8, "Skip", 4)
		Test.assertTrue(not ok and reason == "NotResolved", "cannot skip flight")
		Test.assertTrue(not Gate.canPitch(g))
		Gate.resolve(g, 8, 7)
		ok, reason = Gate.request(g, 17, 5, 7, "Ready", 8)
		Test.assertTrue(not ok and reason == "WrongHit")
		ok, reason = Gate.request(g, 17, 5, 8, "Skip", 9)
		Test.assertTrue(ok and g.phase == "Returning", "confirmed skip")
		ok, reason = Gate.request(g, 17, 5, 8, "Ready", 9.3)
		Test.assertTrue(not ok and reason == "ReturnTooSoon", "cannot lie about immediate return")
		ok = Gate.request(g, 17, 5, 8, "Ready", 9 + Config.Pacing.ReturnSeconds + 0.01)
		Test.assertTrue(ok and Gate.canPitch(g))
		ok, reason = Gate.request(g, 17, 5, 8, "Ready", 11)
		Test.assertTrue(not ok and reason == "AlreadyReady", "duplicate acknowledgement")
	end)
	t.test("malformed or flooded requests cannot ready a lane; recovery never auto-releases", function()
		local g = Gate.new(1, 1, 0)
		Gate.character(g, true, 1)
		local ok, reason = Gate.request(g, 1, 1, 0, "CancelFlight", 0)
		Test.assertTrue(not ok and reason == "Malformed")
		ok, reason = Gate.request(g, 1, 1, 0, "Ready", 0.01)
		Test.assertTrue(not ok and reason == "RateLimited")
		Gate.begin(g, 1, 1)
		Test.assertTrue(not Gate.recover(g, 100), "no recovery during flight")
		Gate.resolve(g, 1, 100)
		Test.assertTrue(not Gate.recover(g, 100 + Config.Pacing.RecoveryAfterSeconds - 0.01), "bounded watchdog")
		Test.assertTrue(Gate.recover(g, 100 + Config.Pacing.RecoveryAfterSeconds), "request recovery")
		Test.assertTrue(not Gate.canPitch(g), "no time-only unlock")
		Test.assertTrue(not Gate.recover(g, 999), "one recovery command")
		Test.assertTrue(not Gate.canPitch(g), "unresponsive client stays gated")
	end)
	t.test("respawn invalidates old readiness and preserves unresolved authority", function()
		local g = Gate.new(1, 1, 0)
		Gate.character(g, true, 2)
		Gate.begin(g, 1, 1)
		Gate.character(g, false, 3)
		Gate.character(g, true, 4)
		Test.assertEqual(g.phase, "Flying")
		Test.assertTrue(not Gate.canPitch(g), "no new pitch after respawn mid-flight")
		Gate.resolve(g, 1, 5)
		local ok, reason = Gate.request(g, 1, 2, 1, "Ready", 10)
		Test.assertTrue(not ok and reason == "StaleAssignment")
		Test.assertTrue(Gate.request(g, 1, 4, 1, "Ready", 11), "new character readiness")
		local replacement = Gate.new(2, 5, 12)
		replacement.characterReady = true
		Test.assertTrue(not Gate.request(replacement, 1, 4, 1, "Ready", 13), "old occupant cannot unlock new lane")
	end)
	t.test("skipping requires a confirmed outcome and is idempotent during the return", function()
		local hit = makeHit(1, 0)
		local d = Camera.new()
		d:setLane("Test")
		local batting = CameraMath.poseFromCFrame(CFrame.new(0, 10, 12), 70)
		d:begin(0, { pitchId = 1, flight = hit.flight, confirmed = false, endTime = hit.outcome.endTime })
		d:update(0.5, 1 / 60, batting)
		Test.assertTrue(not d:skipResult(0.5, "Test", 1), "prediction cannot skip")
		local endTime = hit.outcome.endTime
		d:update(endTime, 1 / 60, batting)
		Test.assertTrue(not d:skipResult(endTime, "Test", 1), "unconfirmed landing")
		d:resolve("Test", 1, Landing.toPayload(hit.outcome))
		local before = d.lastPose
		Test.assertTrue(d:skipResult(endTime, "Test", 1), "skip after server result")
		local returnStart = d.stateStart
		Test.assertTrue(not d:skipResult(endTime + 0.1, "Test", 1), "duplicate skip")
		Test.assertEqual(d.stateStart, returnStart, "does not restart return")
		assert(before, "camera pose before skip")
		local returned = d:update(endTime, 1 / 60, batting)
		Test.assertTrue((returned.position - before.position).Magnitude < 1e-5, "continuous camera pose")
		d:update(endTime + Presentation.Timing.ReturnSeconds + 0.01, 1 / 60, batting)
		Test.assertTrue(d:isBattingView(), "back at the plate")
		Test.assertEqual(hit.flight.launch.hitId, 1, "authoritative flight untouched")
	end)
	t.test("coordinated lifecycle waits for readiness instead of the old fixed hold", function()
		local hit = makeHit(1, 0)
		local gate = Gate.new(1, 1, 0)
		gate.characterReady = true
		Gate.begin(gate, 1, 1)
		local resolved, finished = 0, 0
		local life = Lifecycle.new("Test", {
			onResolved = function(_, active)
				resolved += 1
				Gate.resolve(gate, active.launch.hitId, hit.outcome.endTime)
			end,
			canFinish = function()
				return Gate.canPitch(gate)
			end,
			onFinished = function()
				finished += 1
			end,
		}, 0)
		life:launch(0, hit)
		life:update(hit.outcome.endTime)
		Test.assertEqual(resolved, 1)
		life:update(hit.outcome.endTime + 30)
		Test.assertEqual(finished, 0, "no fixed-delay finish")
		Gate.request(gate, 1, 1, 1, "Ready", hit.outcome.endTime + 31)
		life:update(hit.outcome.endTime + 31)
		life:update(hit.outcome.endTime + 31)
		Test.assertEqual(finished, 1)
	end)
	t.test("50 complete camera, result, stats and pitch cycles remain synchronized", function()
		local geometry = Test.geometries().straight
		local template = makeHit(1, 0)
		local gate = Gate.new(1, 1, 0)
		gate.characterReady, gate.cameraReady, gate.phase = true, true, "Ready"
		local stats = Stats.new()
		local d = Camera.new()
		d:setLane("Test")
		local batting = CameraMath.poseFromCFrame(CFrame.new(0, 10, 12), 70)
		local now = 0
		local releases = 0
		local lane = PitchLane.new("Test", {
			canStartPitch = function()
				return Gate.canPitch(gate)
			end,
			createPitch = function(_, id, windup, release)
				local data = Pitch.generate(
					geometry,
					Test.rng(10),
					{ id = id, laneId = "Test", windupTime = windup, releaseTime = release }
				)
				return { data = data, flight = Pitch.buildFlight(geometry, data) }
			end,
			onPitchReleased = function(_, pitch)
				releases += 1
				Stats.pitch(stats, "Test", pitch.data.id)
			end,
		})
		lane:start(0, 0)
		local life: Lifecycle.HitLifecycle
		life = Lifecycle.new("Test", {
			onLaunched = function()
				lane:setPaused(true)
			end,
			onResolved = function(_, hit)
				Gate.resolve(gate, hit.launch.hitId, now)
				Stats.resolve(stats, hit.launch.hitId, Landing.toPayload(hit.outcome))
				d:resolve("Test", 1, Landing.toPayload(hit.outcome))
			end,
			canFinish = function()
				return Gate.canPitch(gate)
			end,
			onFinished = function()
				lane:resumeAfterHit(now)
			end,
		}, 0)
		for id = 1, 50 do
			lane:update(now)
			assert(lane.pitch, "pitch after readiness")
			local release = lane.pitch.data.releaseTime
			now = release
			lane:update(now)
			lane:abortPitch(now, "Contact")
			local launch = table.clone(template.launch)
			launch.hitId, launch.launchTime = id, now
			local flight = BattedBall.buildFlight(template.flight.frame, launch)
			local hit = { launch = launch, flight = flight, outcome = template.outcome }
			Gate.begin(gate, id, 1)
			Stats.swing(stats, id, true, true)
			Stats.contact(stats, id, flight.exitSpeedMph)
			life:launch(now, hit)
			d:begin(now, { pitchId = 1, flight = flight, confirmed = true, endTime = hit.outcome.endTime })
			local landing = now + hit.outcome.endTime
			while now < landing + 0.01 do
				now += 1 / 60
				life:update(now)
				d:update(now, 1 / 60, batting)
				lane:update(now)
				Test.assertTrue(lane.pitch == nil, "no pitch during follow")
			end
			if id % 2 == 0 then
				Test.assertTrue(Gate.request(gate, 1, 1, id, "Skip", now), "skip alternate results")
				Test.assertTrue(d:skipResult(now, "Test", 1), "approved skip")
			end
			while not d:isBattingView() do
				now += 1 / 60
				d:update(now, 1 / 60, batting)
				life:update(now)
				lane:update(now)
				Test.assertTrue(lane.pitch == nil, "no pitch during return")
			end
			Test.assertTrue(now - landing < 2.0, "short coordinated presentation")
			Test.assertTrue(Gate.request(gate, 1, 1, id, "Ready", now), "camera ready")
			life:update(now)
			Test.assertTrue(not life:isBusy(), "one finish per hit")
		end
		Test.assertEqual(stats.value.contacts, 50)
		Test.assertEqual(stats.value.measuredFairHits, 50)
		Test.assertEqual(releases, 50)
		Test.assertEqual(stats.value.pitches, 50)
		Test.assertEqual(life.resolved, 50)
		Test.assertEqual(life.finished, 50)
	end)
end
