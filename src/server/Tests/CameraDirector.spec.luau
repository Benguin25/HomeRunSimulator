--!strict
-- The hit camera's state machine (Stage 4), driven with real deterministic
-- flights and the server clock exactly as the client drives it, at several
-- frame rates. Pure: no Camera, no Instances.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BattedBall = require(Shared.BattedBall.BattedBall)
local BattedBallConfig = require(Shared.BattedBall.BattedBallConfig)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local LandingDetector = require(Shared.BattedBall.LandingDetector)
local CameraDirector = require(Shared.Presentation.CameraDirector)
local CameraMath = require(Shared.Presentation.CameraMath)
local PresentationConfig = require(Shared.Presentation.PresentationConfig)

local BattedBallTestUtil = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local EPOCH = BattedBallTestUtil.EPOCH
local LANE = "Test" -- BattedBallTestUtil launches are on this lane, pitch #1

type Setup = {
	frame: FieldFrame.Frame,
	flight: BattedBall.Flight,
	outcome: LandingDetector.OutcomePayload,
	batting: CameraMath.Pose,
}

type Sample = {
	now: number,
	pose: CameraMath.Pose,
	state: CameraDirector.State,
	focus: Vector3?,
}

local SPECS: { [string]: BattedBallTestUtil.LaunchSpec } = {
	grounder = { speedMph = 75, launchDegrees = 4, backspinRpm = -500 },
	liner = { speedMph = 80, launchDegrees = 15, backspinRpm = 900 },
	fly = { speedMph = 76, launchDegrees = 30, backspinRpm = 2100 },
	popup = { speedMph = 62, launchDegrees = 72, backspinRpm = 3500, sprayDegrees = 3 },
}

local function setup(spec: BattedBallTestUtil.LaunchSpec, geometryName: string?): Setup
	local geometry = TestUtil.geometries()[geometryName or "straight"]
	local frame = FieldFrame.new(geometry)
	local flight = BattedBallTestUtil.flight(frame, spec)
	local scene = BattedBallTestUtil.scene(frame, { BattedBallTestUtil.ground() })
	local outcome = LandingDetector.toPayload(LandingDetector.evaluate(flight, scene.caster))
	local s = frame.studsPerMeter
	local batting = CameraMath.lookPose(frame.origin - frame.forward * 3.4 * s + frame.up * 1.6 * s, frame.origin + frame.forward * 8 * s, 55)
	return { frame = frame, flight = flight, outcome = outcome, batting = batting }
end

local function newDirector(): CameraDirector.CameraDirector
	local director = CameraDirector.new()
	director:setLane(LANE)
	return director
end

type Event = { at: number, run: (now: number) -> (), fired: boolean? }

-- Steps the director from `from` to `to` (server time) at `fps`, firing events on time.
local function run(director: CameraDirector.CameraDirector, batting: CameraMath.Pose, fps: number, from: number, to: number, events: { Event }?): { Sample }
	local samples: { Sample } = {}
	local frames = math.floor((to - from) * fps + 0.5)
	for i = 0, frames do
		local now = from + i / fps
		for _, event in events or ({} :: { Event }) do
			if not event.fired and now >= event.at then
				event.fired = true
				event.run(now)
			end
		end
		local pose = director:update(now, if i == 0 then 0 else 1 / fps, batting)
		table.insert(samples, { now = now, pose = pose, state = director:getState(), focus = director.debug.focus })
	end
	return samples
end

local function stateSequence(samples: { Sample }): { string }
	local sequence = {}
	for _, sample in samples do
		if sequence[#sequence] ~= sample.state then
			table.insert(sequence, sample.state)
		end
	end
	return sequence
end

-- The normal lifecycle of one hit: predicted at the click, confirmed, resolved at the landing.
local function standardEvents(director: CameraDirector.CameraDirector, s: Setup): { Event }
	local flight, outcome = s.flight, s.outcome
	return {
		{
			at = EPOCH - 0.2,
			run = function(now)
				director:begin(now, { pitchId = 1, flight = flight, endTime = nil, confirmed = false })
			end,
		},
		{
			at = EPOCH + 0.08,
			run = function()
				director:confirm(LANE, 1, outcome.endTime)
			end,
		},
		{
			at = EPOCH + outcome.endTime + 0.05,
			run = function()
				director:resolve(LANE, 1, outcome)
			end,
		},
	}
end

local function cycleSeconds(outcome: LandingDetector.OutcomePayload): number
	local timing = PresentationConfig.Timing
	return outcome.endTime + timing.LandingHoldSeconds + timing.ReturnSeconds + 0.3
end

local function angleBetween(a: Vector3, b: Vector3): number
	return math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1))
end

local function samePose(a: CameraMath.Pose, b: CameraMath.Pose): boolean
	return (a.position - b.position).Magnitude < 1e-6 and math.abs(a.yaw - b.yaw) < 1e-9 and math.abs(a.pitch - b.pitch) < 1e-9
end

return function(t)
	t.test("full cycle: Batting -> ContactTransition -> BallFollow -> Landing -> Returning -> Batting", function()
		for _, geometryName in { "straight", "rotated" } do
			local s = setup(SPECS.fly, geometryName)
			local director = newDirector()
			local samples = run(director, s.batting, 60, EPOCH - 0.5, EPOCH + cycleSeconds(s.outcome), standardEvents(director, s))
			local sequence = table.concat(stateSequence(samples), ",")
			TestUtil.assertEqual(sequence, "Batting,ContactTransition,BallFollow,Landing,Returning,Batting", geometryName)
			TestUtil.assertTrue(director:getHit() == nil, "hit cleared after the return")
			TestUtil.assertTrue(samePose(samples[#samples].pose, s.batting), "ends exactly on the batting framing")
			-- The fly-back from ~80 m out stays comfortable (sine ease: peak ~1.6x the average speed).
			local worst = 0
			for i = 2, #samples do
				if samples[i].state == "Returning" then
					worst = math.max(worst, (samples[i].pose.position - samples[i - 1].pose.position).Magnitude * s.frame.metersPerStud)
				end
			end
			TestUtil.assertTrue(worst < 3, `return moves {worst} m in one 60 fps frame`)
		end
	end)

	t.test("the camera stays on the batter until the contact time", function()
		local s = setup(SPECS.liner)
		local director = newDirector()
		local samples = run(director, s.batting, 60, EPOCH - 0.5, EPOCH + 0.5, standardEvents(director, s))
		for _, sample in samples do
			if sample.now < EPOCH then
				TestUtil.assertEqual(sample.state, "Batting", "before contact")
				TestUtil.assertTrue(samePose(sample.pose, s.batting), "pose before contact")
			end
		end
		-- The contact hold keeps the batting framing for a beat, then it blends (no snap).
		local maxStep = 0
		for i = 2, #samples do
			maxStep = math.max(maxStep, (samples[i].pose.position - samples[i - 1].pose.position).Magnitude * s.frame.metersPerStud)
		end
		TestUtil.assertTrue(maxStep < 1.5, `largest per-frame camera move {maxStep} m`)
	end)

	t.test("a prediction rejected before contact never leaves the batter", function()
		local s = setup(SPECS.fly)
		local director = newDirector()
		local samples = run(director, s.batting, 60, EPOCH - 0.5, EPOCH + 2, {
			{
				at = EPOCH - 0.2,
				run = function(now)
					director:begin(now, { pitchId = 1, flight = s.flight, confirmed = false })
				end,
			},
			{
				at = EPOCH - 0.05,
				run = function(now)
					director:cancel(now, LANE, 1, "server: no contact")
				end,
			},
		})
		TestUtil.assertEqual(table.concat(stateSequence(samples), ","), "Batting")
		TestUtil.assertTrue(director:getHit() == nil, "no hit left")
	end)

	t.test("a prediction rejected after contact returns smoothly and ends batting", function()
		local s = setup(SPECS.fly)
		local director = newDirector()
		local samples = run(director, s.batting, 60, EPOCH - 0.3, EPOCH + 2.5, {
			{
				at = EPOCH - 0.2,
				run = function(now)
					director:begin(now, { pitchId = 1, flight = s.flight, confirmed = false })
				end,
			},
			{
				at = EPOCH + 0.6,
				run = function(now)
					director:cancel(now, LANE, 1, "prediction timed out")
				end,
			},
		})
		TestUtil.assertEqual(table.concat(stateSequence(samples), ","), "Batting,ContactTransition,BallFollow,Returning,Batting")
		TestUtil.assertTrue(samePose(samples[#samples].pose, s.batting), "back on the batter")
		for i = 2, #samples do
			local step = (samples[i].pose.position - samples[i - 1].pose.position).Magnitude * s.frame.metersPerStud
			TestUtil.assertTrue(step < 3, `jump of {step} m during the return`)
		end
	end)

	t.test("a server correction swaps the flight without a camera jump", function()
		local s = setup(SPECS.fly)
		local corrected = BattedBallTestUtil.flight(s.frame, { speedMph = 74, launchDegrees = 31, backspinRpm = 2050 })
		local director = newDirector()
		local events = standardEvents(director, s)
		events[2] = {
			at = EPOCH + 0.15,
			run = function(now)
				director:begin(now, { pitchId = 1, flight = corrected, endTime = corrected.trajectory.duration, confirmed = true })
			end,
		}
		events[3].fired = true -- the outcome belongs to the original flight; not needed here
		local samples = run(director, s.batting, 60, EPOCH - 0.3, EPOCH + 2, events)
		TestUtil.assertEqual(director.corrections, 1, "one correction")
		local hit = director:getHit()
		TestUtil.assertTrue(hit ~= nil and hit.flight == corrected and hit.confirmed, "follows the server's flight")
		local worst = 0
		for i = 2, #samples do
			if samples[i].now > EPOCH + 0.5 then
				worst = math.max(worst, (samples[i].pose.position - samples[i - 1].pose.position).Magnitude * s.frame.metersPerStud)
			end
		end
		TestUtil.assertTrue(worst < 1.2, `per-frame move after correction {worst} m`)
	end)

	t.test("grounders, line drives, fly balls and pop-ups keep the ball framed and the camera above the field", function()
		local results: { [string]: { height: number, distance: number, profile: string } } = {}
		for name, spec in SPECS do
			local s = setup(spec)
			local director = newDirector()
			local events = standardEvents(director, s)
			local samples = run(director, s.batting, 60, EPOCH - 0.2, EPOCH + 0.05, events)
			local hit = assert(director:getHit(), "hit after contact")
			for _, sample in run(director, s.batting, 60, EPOCH + 0.05 + 1 / 60, EPOCH + cycleSeconds(s.outcome), events) do
				table.insert(samples, sample)
			end
			local s2m = s.frame.metersPerStud
			local minHeight = PresentationConfig.Camera.MinHeightAboveField
			local heightSum, distanceSum, count = 0, 0, 0
			for _, sample in samples do
				local focus = sample.focus
				if focus and (sample.state == "BallFollow" or sample.state == "Landing") then
					local pose = sample.pose
					local look = CameraMath.direction(pose.yaw, pose.pitch)
					local off = angleBetween(look, focus - pose.position)
					TestUtil.assertTrue(off < math.rad(pose.fov / 2) * 0.9, string.format("%s: ball %.1f deg off-axis (fov %.0f)", name, math.deg(off), pose.fov))
					local height = (pose.position - s.frame.origin):Dot(s.frame.up) * s2m
					TestUtil.assertTrue(height >= minHeight - 1e-3, `{name}: camera {height} m above the field`)
					TestUtil.assertTrue(math.abs(pose.pitch) <= math.rad(PresentationConfig.Camera.MaxPitchDegrees) + 1e-9, "pitch limit")
					heightSum += height - (focus - s.frame.origin):Dot(s.frame.up) * s2m
					distanceSum += (pose.position - focus).Magnitude * s2m
					count += 1
				end
			end
			TestUtil.assertTrue(count > 10, `{name}: followed for {count} frames`)
			results[name] = { height = heightSum / count, distance = distanceSum / count, profile = hit.profile.name }
		end
		TestUtil.assertEqual(results.grounder.profile, "Grounder")
		TestUtil.assertEqual(results.liner.profile, "LineDrive")
		TestUtil.assertEqual(results.fly.profile, "FlyBall")
		TestUtil.assertEqual(results.popup.profile, "PopUp")
		TestUtil.assertTrue(results.fly.distance > results.grounder.distance, "fly balls pull back further than grounders")
		TestUtil.assertTrue(results.grounder.height < results.fly.height + 3, "grounders stay low")
	end)

	t.test("powerful hits pull back and widen the field of view, within limits", function()
		local function meanFovAndDistance(speedMph: number): (number, number)
			local s = setup({ speedMph = speedMph, launchDegrees = 22, backspinRpm = 1500 })
			local director = newDirector()
			local samples = run(director, s.batting, 60, EPOCH - 0.2, EPOCH + 1.5, standardEvents(director, s))
			local fov, distance, n = 0, 0, 0
			for _, sample in samples do
				local focus = sample.focus
				if focus and sample.state == "BallFollow" then
					fov += sample.pose.fov
					distance += (sample.pose.position - focus).Magnitude * s.frame.metersPerStud
					n += 1
				end
			end
			return fov / n, distance / n
		end
		local weakFov, weakDistance = meanFovAndDistance(55)
		local strongFov, strongDistance = meanFovAndDistance(105)
		local hugeFov = meanFovAndDistance(300)
		TestUtil.assertTrue(strongFov > weakFov + 2, `fov {weakFov} -> {strongFov}`)
		TestUtil.assertTrue(strongDistance > weakDistance, `distance {weakDistance} -> {strongDistance}`)
		local cap = PresentationConfig.Profiles[#PresentationConfig.Profiles].FieldOfView + PresentationConfig.Camera.PowerFovBonus
		TestUtil.assertTrue(hugeFov <= cap + 0.5, `300 mph fov {hugeFov} stays under {cap}`)
	end)

	t.test("the same hit looks the same at 30, 60, 120, 144 and 240 fps", function()
		local s = setup(SPECS.fly)
		local function at(fps: number): { [number]: CameraMath.Pose }
			local director = newDirector()
			local samples = run(director, s.batting, fps, EPOCH - 0.5, EPOCH + cycleSeconds(s.outcome), standardEvents(director, s))
			local byHalfSecond = {}
			for _, sample in samples do
				local k = (sample.now - EPOCH) * 2
				if math.abs(k - math.floor(k + 0.5)) < 1e-6 then
					byHalfSecond[math.floor(k + 0.5)] = sample.pose
				end
			end
			return byHalfSecond
		end
		local reference = at(240)
		local worstPosition, worstAngle = 0, 0
		for _, fps in { 30, 60, 120, 144 } do
			for k, pose in at(fps) do
				local ref = reference[k]
				if ref then
					worstPosition = math.max(worstPosition, (pose.position - ref.position).Magnitude * s.frame.metersPerStud)
					worstAngle = math.max(worstAngle, math.abs(CameraMath.wrapAngle(pose.yaw - ref.yaw)), math.abs(pose.pitch - ref.pitch))
				end
			end
		end
		TestUtil.assertTrue(worstPosition < 0.25, `position differs by {worstPosition} m across frame rates`)
		TestUtil.assertTrue(worstAngle < math.rad(1.5), `orientation differs by {math.deg(worstAngle)} deg across frame rates`)
	end)

	t.test("orientation stays stable through a pop-up's apex (no flips, no snaps)", function()
		local s = setup(SPECS.popup)
		local director = newDirector()
		local samples = run(director, s.batting, 60, EPOCH - 0.2, EPOCH + s.outcome.endTime + 1, standardEvents(director, s))
		local worstYaw, worstPitch = 0, 0
		local firstYaw: number? = nil
		local widest = 0
		for i = 2, #samples do
			local a, b = samples[i - 1], samples[i]
			if b.state == "BallFollow" or b.state == "Landing" then
				worstYaw = math.max(worstYaw, math.abs(CameraMath.wrapAngle(b.pose.yaw - a.pose.yaw)))
				worstPitch = math.max(worstPitch, math.abs(b.pose.pitch - a.pose.pitch))
				firstYaw = firstYaw or b.pose.yaw
				widest = math.max(widest, math.abs(CameraMath.wrapAngle(b.pose.yaw - (firstYaw :: number))))
			end
		end
		TestUtil.assertTrue(worstYaw < math.rad(2.5), `yaw step {math.deg(worstYaw)} deg`)
		TestUtil.assertTrue(worstPitch < math.rad(2.5), `pitch step {math.deg(worstPitch)} deg`)
		TestUtil.assertTrue(widest < math.rad(60), `yaw swung {math.deg(widest)} deg`)
	end)

	t.test("a ball that lands during the contact blend still blends (no snap)", function()
		local s = setup({ speedMph = 70, launchDegrees = -8, backspinRpm = -1500 })
		TestUtil.assertTrue(s.outcome.endTime < PresentationConfig.Timing.ContactTransitionSeconds, "lands during the blend")
		local director = newDirector()
		local samples = run(director, s.batting, 60, EPOCH - 0.2, EPOCH + cycleSeconds(s.outcome), standardEvents(director, s))
		TestUtil.assertEqual(table.concat(stateSequence(samples), ","), "Batting,ContactTransition,Landing,Returning,Batting")
		for i = 2, #samples do
			local step = (samples[i].pose.position - samples[i - 1].pose.position).Magnitude * s.frame.metersPerStud
			TestUtil.assertTrue(step < 1.5, `jump of {step} m`)
		end
	end)

	t.test("no server outcome: the camera still returns after the grace period", function()
		local s = setup(SPECS.liner)
		local director = newDirector()
		local events = standardEvents(director, s)
		events[3].fired = true -- the Resolved message never arrives
		local timing = PresentationConfig.Timing
		local landing = EPOCH + s.outcome.endTime
		local samples = run(director, s.batting, 60, EPOCH - 0.2, landing + timing.LandingHoldSeconds + timing.OutcomeGraceSeconds + timing.ReturnSeconds + 0.2, events)
		TestUtil.assertEqual(director:getState(), "Batting")
		for _, sample in samples do
			if sample.state == "Returning" then
				TestUtil.assertTrue(sample.now >= landing + timing.LandingHoldSeconds + timing.OutcomeGraceSeconds - 1e-6, "waited for the result")
				break
			end
		end
	end)

	t.test("interruptions: reset mid-flight, watchdog and respawn never strand the camera", function()
		local s = setup(SPECS.fly)
		-- Reset (left the lane / session ended).
		local director = newDirector()
		run(director, s.batting, 60, EPOCH - 0.2, EPOCH + 1, standardEvents(director, s))
		TestUtil.assertEqual(director:getState(), "BallFollow")
		director:reset("left the lane")
		TestUtil.assertEqual(director:getState(), "Batting")
		TestUtil.assertTrue(samePose(director:update(EPOCH + 1.1, 1 / 60, s.batting), s.batting), "immediately batting")

		-- Respawn: cancel whatever is presented.
		local d2 = newDirector()
		run(d2, s.batting, 60, EPOCH - 0.2, EPOCH + 1, standardEvents(d2, s))
		d2:cancel(EPOCH + 1, nil, nil, "respawned")
		run(d2, s.batting, 60, EPOCH + 1, EPOCH + 1 + PresentationConfig.Timing.ReturnSeconds + 0.05)
		TestUtil.assertEqual(d2:getState(), "Batting", "respawn")

		-- Watchdog.
		local timing = PresentationConfig.Timing :: any
		local saved = timing.MaxHitSeconds
		timing.MaxHitSeconds = 0.8
		local ok, err = pcall(function()
			local d3 = newDirector()
			local samples = run(d3, s.batting, 60, EPOCH - 0.2, EPOCH + 0.8 + PresentationConfig.Timing.ReturnSeconds + 0.1, standardEvents(d3, s))
			TestUtil.assertEqual(table.concat(stateSequence(samples), ","), "Batting,ContactTransition,BallFollow,Returning,Batting", "watchdog")
		end)
		timing.MaxHitSeconds = saved
		if not ok then
			error(err, 0)
		end
	end)

	t.test("hits on other lanes and events for other pitches are ignored", function()
		local s = setup(SPECS.fly)
		local director = newDirector()
		local other = table.clone(s.flight)
		other.launch = table.clone(s.flight.launch)
		other.launch.laneId = "OtherLane"
		TestUtil.assertTrue(not director:begin(EPOCH - 0.1, { pitchId = 1, flight = other, confirmed = true }), "other lane refused")
		TestUtil.assertTrue(director:getHit() == nil, "no hit from another lane")

		director:begin(EPOCH - 0.1, { pitchId = 1, flight = s.flight, confirmed = false })
		director:resolve("OtherLane", 1, s.outcome)
		director:resolve(LANE, 2, s.outcome)
		director:confirm("OtherLane", 1, 0.1)
		director:cancel(EPOCH, "OtherLane", 1, "other lane")
		director:cancel(EPOCH, LANE, 7, "other pitch")
		local hit = director:getHit()
		TestUtil.assertTrue(hit ~= nil and hit.outcome == nil and hit.endTime == nil, "untouched by foreign events")

		-- Two directors (two players) never affect each other.
		local d2 = CameraDirector.new()
		d2:setLane("OtherLane")
		d2:begin(EPOCH - 0.1, { pitchId = 1, flight = other, confirmed = true })
		run(director, s.batting, 60, EPOCH - 0.1, EPOCH + 0.6)
		TestUtil.assertEqual(d2:getState(), "Batting", "the other director was never updated")
		TestUtil.assertEqual(director:getState(), "BallFollow")
	end)

	t.test("50 repeated hits always come back to batting with nothing left over", function()
		local s = setup(SPECS.liner)
		local director = newDirector()
		local cycle = cycleSeconds(s.outcome)
		local start = EPOCH
		for i = 1, 50 do
			local launch = table.clone(s.flight.launch)
			launch.launchTime = start
			launch.pitchId = i
			local flight = table.clone(s.flight)
			flight.launch = launch
			local outcome = s.outcome
			run(director, s.batting, 60, start - 0.3, start + cycle, {
				{
					at = start - 0.2,
					run = function(now)
						director:begin(now, { pitchId = i, flight = flight, confirmed = false })
					end,
				},
				{
					at = start + 0.1,
					run = function()
						director:confirm(LANE, i, outcome.endTime)
					end,
				},
				{
					at = start + outcome.endTime,
					run = function()
						director:resolve(LANE, i, outcome)
					end,
				},
			})
			TestUtil.assertEqual(director:getState(), "Batting", `hit {i}`)
			TestUtil.assertTrue(director:getHit() == nil and director.returningHit == nil and director.fromPose == nil, `leftovers after hit {i}`)
			start += cycle + 0.5
		end
		TestUtil.assertEqual(director.transitions, 50 * 5, "five transitions per hit")
	end)

	t.test("landing hold + return fit inside the server's post-landing hold", function()
		local timing = PresentationConfig.Timing
		local needed = timing.LandingHoldSeconds + timing.ReturnSeconds
		TestUtil.assertTrue(
			BattedBallConfig.Lifecycle.ResultHoldSeconds >= needed + 0.1,
			`ResultHoldSeconds {BattedBallConfig.Lifecycle.ResultHoldSeconds} < {needed} + margin`
		)
		TestUtil.assertTrue(BattedBallConfig.Display.LandedHoldSeconds >= timing.LandingHoldSeconds, "ball visible through the landing hold")
	end)
end
