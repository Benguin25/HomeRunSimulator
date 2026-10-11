--!strict
-- Pitch lifecycle tests driven by a fake clock (pure Luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local Pitch = require(Pitching.Pitch)
local PitchConfig = require(Pitching.PitchConfig)
local PitchLane = require(Pitching.PitchLane)

local TestUtil = require(script.Parent.TestUtil)

type Harness = {
	lane: PitchLane.PitchLane,
	events: { string },
	live: number, -- pitches started but not finished/aborted
	maxLive: number,
	crossings: { [number]: number },
	finished: { [number]: boolean },
}

local function makeLane(seed: number): Harness
	local geometry = TestUtil.geometries().straight
	local rng = TestUtil.rng(seed)
	local harness: Harness = {
		lane = nil :: any,
		events = {},
		live = 0,
		maxLive = 0,
		crossings = {},
		finished = {},
	}
	harness.lane = PitchLane.new("Test", {
		createPitch = function(_lane, id, windupTime, releaseTime)
			local data = Pitch.generate(geometry, rng, {
				id = id,
				laneId = "Test",
				windupTime = windupTime,
				releaseTime = releaseTime,
			})
			return { data = data, flight = Pitch.buildFlight(geometry, data) }
		end,
		onStateChanged = function(_lane, state)
			table.insert(harness.events, state)
		end,
		onPitchStarted = function(_lane, _pitch)
			harness.live += 1
			harness.maxLive = math.max(harness.maxLive, harness.live)
		end,
		onPitchCrossed = function(_lane, pitch)
			harness.crossings[pitch.data.id] = (harness.crossings[pitch.data.id] or 0) + 1
		end,
		onPitchFinished = function(_lane, pitch)
			harness.live -= 1
			harness.finished[pitch.data.id] = true
		end,
		onPitchAborted = function(_lane, _pitch, _reason)
			harness.live -= 1
		end,
	})
	return harness
end

-- Drives the lane with a frame schedule until `untilTime`.
local function run(harness: Harness, startTime: number, untilTime: number, nextDt: () -> number): number
	local now = startTime
	while now < untilTime do
		now += nextDt()
		harness.lane:update(now)
	end
	return now
end

local function cycleSeconds(): number
	local timing = PitchConfig.Timing
	return timing.ReadySeconds + timing.WindupSeconds + 1 + timing.ResetSeconds
end

return function(t)
	t.test("states follow Ready -> Windup -> Released -> Approaching -> Crossed -> Finished -> Resetting", function()
		local harness = makeLane(1)
		harness.lane:start(0, 0)
		run(harness, 0, cycleSeconds(), function()
			return 1 / 60
		end)
		local expected = { "Ready", "Windup", "Released", "Approaching", "Crossed", "Finished", "Resetting", "Ready" }
		for i, state in expected do
			TestUtil.assertEqual(harness.events[i], state, `event {i}`)
		end
	end)

	t.test("repeated pitches never overlap and leave nothing active", function()
		local harness = makeLane(2)
		harness.lane:start(0, 0)
		local now = run(harness, 0, cycleSeconds() * 40, function()
			return 1 / 60
		end)
		local lane = harness.lane
		TestUtil.assertTrue(lane.pitchesStarted >= 20, `only {lane.pitchesStarted} pitches ran`)
		TestUtil.assertEqual(harness.maxLive, 1, "max simultaneous pitches")
		-- Stop and make sure nothing is left behind.
		lane:stop(now, "TestEnd")
		TestUtil.assertEqual(harness.live, 0, "live pitches after stop")
		TestUtil.assertTrue(lane.pitch == nil, "lane still holds a pitch")
		TestUtil.assertEqual(lane.pitchesStarted, lane.pitchesFinished + lane.pitchesAborted, "start/finish balance")
		TestUtil.assertEqual(lane.state, "Idle", "state after stop")
	end)

	t.test("every pitch registers exactly one crossing even with huge frame hitches", function()
		local rng = TestUtil.rng(9)
		local harness = makeLane(3)
		harness.lane:start(0, 0)
		-- Frames between 1 ms and 1.5 s: some frames span the entire flight.
		run(harness, 0, cycleSeconds() * 25, function()
			return rng:NextNumber(0.001, 1.5)
		end)
		local lane = harness.lane
		TestUtil.assertTrue(lane.pitchesFinished >= 5, "not enough pitches finished")
		for id in harness.finished do
			TestUtil.assertEqual(harness.crossings[id], 1, `crossings for pitch {id}`)
		end
		TestUtil.assertEqual(harness.maxLive, 1, "max simultaneous pitches")
	end)

	t.test("crossing is reported at the trajectory's crossing time, not a frame time", function()
		local harness = makeLane(4)
		local crossedAt: number? = nil
		local hooks = harness.lane.hooks
		local previous = hooks.onStateChanged
		hooks.onStateChanged = function(lane, state, now)
			if state == "Crossed" and crossedAt == nil then
				crossedAt = now
			end
			if previous then
				previous(lane, state, now)
			end
		end
		harness.lane:start(0, 0)
		local expectedCross: number? = nil
		run(harness, 0, cycleSeconds(), function()
			expectedCross = expectedCross or harness.lane:getCrossServerTime()
			return 0.25 -- 4 fps
		end)
		assert(crossedAt and expectedCross, "no crossing observed")
		TestUtil.assertNear(crossedAt, expectedCross, 1e-9, "crossing timestamp")
	end)

	t.test("release happens exactly one windup after the windup starts", function()
		local harness = makeLane(8)
		local lane = harness.lane
		local released: number? = nil
		local windupStart: number? = nil
		local previous = lane.hooks.onStateChanged
		lane.hooks.onStateChanged = function(l, state, now)
			if state == "Windup" and windupStart == nil then
				windupStart = now
			elseif state == "Released" and released == nil then
				released = now
			end
			if previous then
				previous(l, state, now)
			end
		end
		lane:start(0, 0)
		run(harness, 0, cycleSeconds(), function()
			return 1 / 60
		end)
		assert(windupStart and released, "no release observed")
		TestUtil.assertNear(released - windupStart, PitchConfig.Timing.WindupSeconds, 1e-9, "windup duration")
		TestUtil.assertTrue(PitchConfig.Timing.WindupSeconds >= 1.5, "beginner windup should give a clear cue")
	end)

	t.test("pause holds the next pitch; resume continues", function()
		local harness = makeLane(5)
		local lane = harness.lane
		lane:start(0, 0)
		local now = run(harness, 0, 0.1, function()
			return 1 / 60
		end)
		local started = lane.pitchesStarted
		lane:setPaused(true)
		now = run(harness, now, now + cycleSeconds() * 3, function()
			return 1 / 60
		end)
		-- At most the pitch already in progress finishes; no new ones begin.
		TestUtil.assertTrue(lane.pitchesStarted == started, "pitch started while paused")
		TestUtil.assertEqual(lane.state, "Ready", "paused lane waits in Ready")
		lane:setPaused(false)
		run(harness, now, now + cycleSeconds() * 2, function()
			return 1 / 60
		end)
		TestUtil.assertTrue(lane.pitchesStarted > started, "lane did not resume")
	end)

	t.test("aborting mid-flight cleans up and recovers", function()
		local harness = makeLane(6)
		local lane = harness.lane
		lane:start(0, 0)
		local now = 0
		while lane.state ~= "Approaching" do
			now += 1 / 60
			lane:update(now)
		end
		TestUtil.assertTrue(lane:abortPitch(now, "Test"), "abort returned false")
		TestUtil.assertTrue(lane.pitch == nil, "pitch not cleared")
		TestUtil.assertEqual(lane.state, "Resetting", "state after abort")
		TestUtil.assertEqual(harness.live, 0, "live after abort")
		TestUtil.assertTrue(not lane:abortPitch(now, "Again"), "double abort should be a no-op")
		run(harness, now, now + cycleSeconds() * 2, function()
			return 1 / 60
		end)
		TestUtil.assertTrue(lane.pitchesFinished >= 1, "lane did not recover after abort")
	end)

	t.test("start is idempotent and stop/start cycles do not duplicate pitches", function()
		local harness = makeLane(7)
		local lane = harness.lane
		local now = 0
		for _ = 1, 10 do
			lane:start(now, 0)
			lane:start(now, 0) -- duplicate start (e.g. CharacterAdded twice)
			now = run(harness, now, now + 1.3, function()
				return 1 / 30
			end)
			lane:stop(now, "Respawn")
			TestUtil.assertEqual(harness.live, 0, "live after stop")
		end
		TestUtil.assertEqual(harness.maxLive, 1, "max simultaneous pitches")
	end)
end
