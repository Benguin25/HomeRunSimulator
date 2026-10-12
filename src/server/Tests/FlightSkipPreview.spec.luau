--!strict
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Gate = require(Shared.Gameplay.ReturnGate)
local Config = require(Shared.Gameplay.GameplayConfig)
local Camera = require(Shared.Presentation.CameraDirector)
local Math = require(Shared.Presentation.CameraMath)
local Edge = require(Shared.Presentation.ActionInput)
local Preview = require(Shared.Presentation.PitchPreview)
local PreviewConfig = require(Shared.Presentation.PitchPreviewConfig)
local Toggle = require(Shared.Presentation.DebugToggle)
local PitchConfig = require(Shared.Pitching.PitchConfig)
local Physics = require(Shared.Pitching.PitchPhysics)
local Swing = require(Shared.Batting.SwingModel)
local Resolver = require(Shared.Batting.SwingResolver)
local Ball = require(Shared.BattedBall.BattedBall)
local Lifecycle = require(Shared.BattedBall.HitLifecycle)
local Landing = require(Shared.BattedBall.LandingDetector)
local Field = require(Shared.BattedBall.FieldFrame)
local Stats = require(Shared.Gameplay.SessionStats)
local Data = require(Shared.Progression.PlayerProgression)
local Rewards = require(Shared.Progression.ProgressionRules)
local BBTU = require(script.Parent.BattedBallTestUtil)
local Test = require(script.Parent.TestUtil)
local function hit(): Lifecycle.ActiveHit
	local frame = Field.new(Test.geometries().straight)
	local launch = BBTU.launchData(frame, { speedMph = 100, launchDegrees = 28, backspinRpm = 2000 })
	launch.launchTime = 0
	local flight = Ball.buildFlight(frame, launch)
	return {
		launch = launch,
		flight = flight,
		outcome = Landing.evaluate(flight, BBTU.scene(frame, { BBTU.ground() }).caster),
	}
end
local function gate(): Gate.State
	local state = Gate.new(1, 1, 0)
	state.characterReady, state.cameraReady, state.phase = true, true, "Ready"
	Gate.begin(state, 1, 1)
	return state
end
local batting = Math.poseFromCFrame(CFrame.new(0, 10, 12), 70)
return function(t)
	t.test("flight skip changes presentation permission without resolving or releasing the server flight", function()
		local g = gate()
		Test.assertTrue(Gate.request(g, 1, 1, 1, "Skip", 0.25))
		Test.assertEqual(g.phase, "Flying")
		Test.assertTrue(g.presentationSkipped)
		Test.assertEqual(g.resolvedAt, math.huge)
		Test.assertTrue(not Gate.canPitch(g))
		local ok, reason = Gate.request(g, 1, 1, 1, "Ready", 0.5)
		Test.assertTrue(not ok and reason == "ReturnTooSoon")
		Test.assertTrue(Gate.request(g, 1, 1, 1, "Ready", 0.25 + Config.Pacing.ReturnSeconds + 0.01))
		Test.assertTrue(
			g.cameraReady and not Gate.canPitch(g),
			"early camera readiness is retained, not pitch authority"
		)
		Test.assertTrue(Gate.resolve(g, 1, 4))
		Test.assertTrue(Gate.canPitch(g), "server result and readiness now agree")
		Test.assertTrue(not Gate.resolve(g, 1, 5), "duplicate resolution")
	end)
	t.test("resolution arriving before camera return still waits for the minimum and fresh readiness", function()
		local g = gate()
		Gate.request(g, 1, 1, 1, "Skip", 1)
		Gate.resolve(g, 1, 1.1)
		Test.assertEqual(g.phase, "Resolved")
		Test.assertTrue(not Gate.canPitch(g))
		Test.assertTrue(not Gate.request(g, 1, 1, 1, "Ready", 1.3))
		Test.assertTrue(Gate.request(g, 1, 1, 1, "Ready", 1.86))
		Test.assertTrue(Gate.canPitch(g))
	end)
	t.test("landing-result skip and duplicate flight presses cannot restart the server return bound", function()
		local g = gate()
		Gate.resolve(g, 1, 4)
		Test.assertTrue(Gate.request(g, 1, 1, 1, "Skip", 4.1))
		Test.assertEqual(g.phase, "Returning")
		local bound = g.notBefore
		local ok, reason = Gate.request(g, 1, 1, 1, "Skip", 4.3)
		Test.assertTrue(not ok and reason == "NotSkippable")
		Test.assertEqual(g.notBefore, bound)
		Test.assertTrue(Gate.request(g, 1, 1, 1, "Ready", bound + 0.01))
	end)
	t.test("skip intent rejects wrong owner, assignment, hit, dead character and unknown commands", function()
		local g = gate()
		Test.assertTrue(not Gate.request(g, 2, 1, 1, "Skip", 1))
		Test.assertTrue(not Gate.request(g, 1, 2, 1, "Skip", 2))
		Test.assertTrue(not Gate.request(g, 1, 1, 2, "Skip", 3))
		Test.assertTrue(not Gate.request(g, 1, 1, 1, "Resolve", 4))
		g.characterReady = false
		Test.assertTrue(not Gate.request(g, 1, 1, 1, "Skip", 5))
		Test.assertEqual(g.phase, "Flying")
		Test.assertTrue(not g.presentationSkipped)
	end)
	t.test("reset invalidates a flight-skip acknowledgement without canceling its pending outcome", function()
		local g = gate()
		Gate.request(g, 1, 1, 1, "Skip", 1)
		Gate.request(g, 1, 1, 1, "Ready", 2)
		Gate.character(g, false, 2)
		Gate.character(g, true, 3)
		Test.assertTrue(not g.cameraReady and not g.presentationSkipped)
		Test.assertEqual(g.phase, "Flying")
		Test.assertTrue(not Gate.request(g, 1, 1, 1, "Ready", 3))
		Test.assertTrue(Gate.request(g, 1, 3, 1, "Skip", 4))
		Gate.resolve(g, 1, 4.2)
		Test.assertTrue(not Gate.canPitch(g))
		Test.assertTrue(Gate.request(g, 1, 3, 1, "Ready", 5))
		Test.assertTrue(Gate.canPitch(g))
	end)
	t.test("predicted flight skip returns immediately and late authority cannot reopen its camera", function()
		local h, d = hit(), Camera.new()
		d:setLane("Test")
		d:begin(0, { pitchId = 1, flight = h.flight, confirmed = false })
		d:update(0.25, 1 / 60, batting)
		local before = assert(d.lastPose, "follow pose")
		Test.assertTrue(d:skipPresentation(0.25, "Test", 1))
		Test.assertEqual(d:getState(), "Returning")
		local start, transitions = d.stateStart, d.transitions
		Test.assertTrue(not d:skipPresentation(0.3, "Test", 1))
		Test.assertEqual(d.transitions, transitions)
		Test.assertEqual(d.stateStart, start)
		local after = d:update(0.25, 1 / 60, batting)
		Test.assertTrue((before.position - after.position).Magnitude < 1e-5, "smooth return starts from shown pose")
		local corrected = table.clone(h.launch)
		corrected.velocity *= 1.12
		local flight = Ball.buildFlight(h.flight.frame, corrected)
		d:begin(0.4, { pitchId = 1, flight = flight, confirmed = true, endTime = h.outcome.endTime })
		d:confirm("Test", 1, h.outcome.endTime)
		d:resolve("Test", 1, Landing.toPayload(h.outcome))
		d:update(1.2, 1 / 60, batting)
		Test.assertTrue(d:isBattingView())
		d:begin(2, { pitchId = 1, flight = flight, confirmed = true, endTime = h.outcome.endTime })
		d:update(2, 1 / 60, batting)
		Test.assertTrue(d:isBattingView(), "delayed launch after return stays dismissed")
		Test.assertTrue(d:getHit() == nil)
		Test.assertEqual(h.flight.launch.velocity, h.launch.velocity, "flight untouched")
	end)
	t.test("prediction rejection, lane reset and a genuinely new hit do not strand skipped framing", function()
		local h, d = hit(), Camera.new()
		d:setLane("Test")
		d:begin(0, { pitchId = 1, flight = h.flight, confirmed = false })
		d:update(0.25, 1 / 60, batting)
		d:skipPresentation(0.25, "Test", 1)
		d:cancel(0.4, "Test", 1, "prediction rejected")
		d:update(1.2, 1 / 60, batting)
		Test.assertTrue(d:isBattingView())
		local nextLaunch = table.clone(h.launch)
		nextLaunch.launchTime = 2
		d:begin(2, { pitchId = 2, flight = Ball.buildFlight(h.flight.frame, nextLaunch), confirmed = true })
		d:update(2.5, 1 / 60, batting)
		Test.assertEqual(d:getState(), "BallFollow")
		Test.assertTrue(not d:wasSkipped("Test", 1))
		d:reset("lane changed")
		Test.assertTrue(d:getHit() == nil and d.skippedPitch == nil)
	end)
	t.test("priority and processed-input delivery share one key edge without repeats or typing conflicts", function()
		local edge, presses = Edge.new(), 0
		local function route(down: boolean, typing: boolean)
			if Edge.edge(edge, down, typing) then
				presses += 1
			end
		end
		route(true, false) -- action Begin
		route(true, false) -- processed UIS fallback
		route(true, false) -- repeat/held key
		Test.assertEqual(presses, 1)
		route(false, false)
		route(false, false)
		route(true, true)
		route(true, false)
		Test.assertEqual(presses, 1, "typing and still-held key ignored")
		Edge.release(edge)
		route(true, false)
		Test.assertEqual(presses, 2, "focus recovery")
		Test.assertTrue(Config.Hud.SkipInputPriority > 2000 and PreviewConfig.InputPriority > 2000)
		Test.assertTrue(
			Edge.distinct(
				Config.Hud.SkipKey,
				{ PreviewConfig.ToggleKey, PitchConfig.Debug.ToggleKey, Config.Hud.StatsKey }
			)
		)
		for _, key in { "None", "Escape", "F6", "F7", "G" } do
			Test.assertTrue(not Edge.distinct(key, { "F6", "F7", "G" }), "invalid/conflicting key")
		end
	end)
	t.test("pitch preview is the true contact-plane crossing in both lane orientations and batter sides", function()
		for _, side in { "Right", "Left" } do
			BBTU.withBatterSide(side, function()
				for _, geometry in Test.geometries() do
					local pitch = BBTU.pitch(geometry, 537)
					local p = Preview.new(true)
					Preview.setLane(p, "Test")
					Preview.begin(p, geometry, pitch)
					local target = assert(p.target, "crossing exists")
					local plane = Swing.contactPlane(geometry)
					Test.assertNear((target.position - plane.point):Dot(plane.normal), 0, 2e-5, "actual contact plane")
					Test.assertNear(target.crossTime, Resolver.idealContactTime(geometry, pitch) :: number, 1e-6)
					local sampled = Physics.sample(pitch.trajectory, target.crossTime - pitch.data.releaseTime)
					-- Epoch subtraction and Vector3 world transforms lose a few float32
					-- ulps; require agreement within 0.056 mm, not exact scalar time.
					Test.assertTrue((sampled - target.position).Magnitude < 2e-4, "sub-millimeter trajectory agreement")
					Test.assertTrue(
						(target.position - assert(pitch.crossing, "zone crossing").position).Magnitude > 0.01,
						"not the strike-zone target"
					)
				end
			end)
		end
	end)
	t.test(
		"preview replaces one target and ignores old/other-lane results; contact, expiration and lane leave clean it",
		function()
			local geometry = Test.geometries().straight
			local p = Preview.new(true)
			Preview.setLane(p, "Test")
			Toggle.input(p.toggle, true, false)
			local a, b = BBTU.pitch(geometry, 537), BBTU.pitch(geometry, 574)
			Preview.begin(p, geometry, a)
			Preview.begin(p, geometry, b)
			Test.assertTrue(not Preview.begin(p, geometry, a), "late old launch")
			Preview.finish(p, "OtherLane", 574)
			Preview.finish(p, "Test", 537)
			Test.assertEqual(assert(p.target, "current target").pitchId, 574)
			Test.assertTrue(Preview.position(p, b.data.windupTime, true) ~= nil)
			Test.assertTrue(Preview.position(p, b.data.windupTime, false) == nil, "cinematic hides marker")
			Preview.cut(p, "Test", 574, b.data.releaseTime, false)
			Test.assertTrue(Preview.position(p, b.data.releaseTime, true) == nil)
			Preview.uncut(p, "Test", 574)
			Test.assertTrue(
				Preview.position(p, b.data.releaseTime, true) ~= nil,
				"rejected prediction restores incoming pitch"
			)
			Preview.cut(p, "Test", 574, b.data.releaseTime, true)
			Preview.uncut(p, "Test", 574)
			Test.assertTrue(Preview.position(p, b.data.releaseTime, true) == nil, "confirmed contact cannot revive")
			Test.assertTrue(p.target == nil)
			Preview.begin(p, geometry, BBTU.pitch(geometry, 611))
			Preview.position(p, math.huge, true)
			Test.assertTrue(p.target == nil, "expiration")
			Preview.begin(p, geometry, BBTU.pitch(geometry, 648))
			Preview.setLane(p, nil)
			Test.assertTrue(p.target == nil and p.lastPitch == 0, "lane cleanup")
		end
	)
	t.test("F6/F7 toggles are independent, initially hidden and preview is forbidden in published clients", function()
		Test.assertTrue(Preview.allowed(true, true))
		Test.assertTrue(not Preview.allowed(true, false))
		Test.assertTrue(not Preview.allowed(false, true), "even published debug opt-in cannot enable preview")
		local preview, debug = Preview.new(true), Toggle.new(true)
		Test.assertTrue(not preview.toggle.visible and not debug.visible)
		Toggle.input(preview.toggle, true, false)
		Test.assertTrue(preview.toggle.visible and not debug.visible)
		Toggle.input(debug, true, false)
		Test.assertTrue(preview.toggle.visible and debug.visible)
		Toggle.release(debug)
		Toggle.input(debug, true, false)
		Test.assertTrue(preview.toggle.visible and not debug.visible)
		Toggle.release(preview.toggle)
		Toggle.input(preview.toggle, true, false)
		Test.assertTrue(not preview.toggle.visible and not debug.visible)
		Test.assertEqual(PreviewConfig.ToggleKey, "F6")
		Test.assertEqual(PitchConfig.Debug.ToggleKey, "F7")
		local disabled = Preview.new(false)
		Preview.setLane(disabled, "Test")
		Test.assertTrue(
			not Preview.begin(disabled, Test.geometries().straight, BBTU.pitch(Test.geometries().straight, 537))
		)
	end)
	t.test(
		"terminal preview events arriving before a delayed start cannot resurrect an expired/contacted pitch",
		function()
			local geometry = Test.geometries().straight
			local p = Preview.new(true)
			Preview.setLane(p, "Test")
			local pitch = BBTU.pitch(geometry, 537)
			Preview.finish(p, "Test", 537)
			Test.assertTrue(not Preview.begin(p, geometry, pitch))
			Preview.cut(p, "Test", 574, pitch.data.releaseTime, true)
			Test.assertTrue(not Preview.begin(p, geometry, BBTU.pitch(geometry, 574)))
			Test.assertTrue(Preview.begin(p, geometry, BBTU.pitch(geometry, 611)), "a later pitch still works")
		end
	)
	t.test("25 early/landing skip cycles keep rewards authoritative and finish only after both gates", function()
		local template = hit()
		local stats, data = Stats.new(), Data.new()
		local now = 0
		for id = 1, 25 do
			local g, d = Gate.new(1, id, now), Camera.new()
			g.characterReady, g.cameraReady, g.phase = true, true, "Ready"
			d:setLane("Test")
			local launch = table.clone(template.launch)
			launch.hitId, launch.launchTime = id, now
			local flight = Ball.buildFlight(template.flight.frame, launch)
			local record = { launch = launch, flight = flight, outcome = template.outcome }
			local earned = data.earnedCoins
			Stats.contact(stats, id, flight.exitSpeedMph)
			Data.launch(data, id)
			Gate.begin(g, id, id)
			local life = Lifecycle.new("Test", {
				onResolved = function(_, active)
					Test.assertTrue(Gate.resolve(g, id, now))
					local p = Landing.toPayload(active.outcome)
					Stats.resolve(stats, id, p)
					Data.resolve(data, id, p)
					d:resolve("Test", id, p)
				end,
				canFinish = function()
					return Gate.canPitch(g)
				end,
			}, 0)
			life:launch(now, record)
			d:begin(now, { pitchId = id, flight = flight, confirmed = true, endTime = record.outcome.endTime })
			local start = now
			local early = id % 2 == 1
			local skipped, acknowledged = false, false
			while life:isBusy() do
				now += 1 / 60
				d:update(now, 1 / 60, batting)
				if not skipped and ((early and now >= start + 0.25) or (not early and g.phase == "Resolved")) then
					Test.assertTrue(d:skipPresentation(now, "Test", id))
					Test.assertTrue(Gate.request(g, 1, id, id, "Skip", now))
					skipped = true
				end
				if skipped and not acknowledged and d:isBattingView() and now >= g.notBefore then
					Test.assertTrue(Gate.request(g, 1, id, id, "Ready", now))
					acknowledged = true
				end
				if now < start + record.outcome.endTime then
					Test.assertEqual(data.earnedCoins, earned, "no reward from skipping")
					Test.assertTrue(not Gate.canPitch(g), "no pitch before actual resolution")
				end
				life:update(now)
				Test.assertTrue(now < start + 10, "bounded cycle")
			end
			Test.assertTrue(skipped and acknowledged and Gate.canPitch(g))
			Test.assertEqual(life.resolved, 1)
			Test.assertEqual(life.finished, 1)
			Test.assertTrue(not Data.resolve(data, id, Landing.toPayload(record.outcome)))
		end
		Test.assertEqual(stats.value.contacts, 25)
		Test.assertEqual(stats.value.measuredFairHits, 25)
		Test.assertEqual(data.earnedCoins, 25 * Rewards.reward(Landing.toPayload(template.outcome)))
	end)
end
