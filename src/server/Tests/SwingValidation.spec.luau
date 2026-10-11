--!strict
-- Server swing validation: input sanitizing, duplicates, flood guard, aim
-- bounds, timestamps / latency-compensation limits, cooldown and per-pitch
-- limits (pure Luau; Studio + CLI).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Batting = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Batting")
local BattingConfig = require(Batting.BattingConfig)
local SwingModel = require(Batting.SwingModel)
local SwingValidator = require(Batting.SwingValidator)

local TestUtil = require(script.Parent.TestUtil)

local units = TestUtil.units
local EPOCH = 1.7e9
local AIM_X, AIM_Y = 0, units.toStuds(0.8)

local function context(receiveTime: number, overrides: { [string]: any }?): SwingValidator.Context
	local ctx: { [string]: any } = {
		receiveTime = receiveTime,
		ping = 0.08,
		geometry = TestUtil.geometries().straight,
		-- A long pitch window so timing never makes these practice swings by accident.
		pitch = { id = 1, releaseTime = EPOCH - 10, endTime = EPOCH + 100 },
	}
	if overrides then
		-- `false` stands for nil (no lane / no active pitch).
		for key, value in overrides do
			ctx[key] = if value == false then nil else value
		end
	end
	return ctx :: any
end

local function request(seq: number, clientTime: number, aimX: number?, aimY: number?): SwingValidator.Request?
	return SwingValidator.parse(seq, clientTime, aimX or AIM_X, aimY or AIM_Y, nil)
end

local CYCLE = SwingModel.timeline().total

return function(t)
	t.test("a well-formed, on-time swing is accepted against the active pitch", function()
		local state = SwingValidator.newState()
		local v = SwingValidator.validate(state, request(1, EPOCH - 0.04), context(EPOCH))
		TestUtil.assertTrue(v.accepted, `rejected: {v.reason}`)
		TestUtil.assertEqual(v.reason, "Ok", "reason")
		TestUtil.assertEqual(v.pitchId, 1, "pitch id")
		TestUtil.assertEqual(v.effectiveTime, EPOCH - 0.04, "effective time")
		TestUtil.assertTrue(not v.clamped, "should not clamp normal latency")
	end)

	t.test("duplicate and replayed requests are rejected", function()
		local state = SwingValidator.newState()
		TestUtil.assertTrue(SwingValidator.validate(state, request(5, EPOCH), context(EPOCH)).accepted, "first")
		TestUtil.assertEqual(SwingValidator.validate(state, request(5, EPOCH), context(EPOCH + 2)).reason, "Duplicate", "same seq")
		TestUtil.assertEqual(SwingValidator.validate(state, request(3, EPOCH + 2), context(EPOCH + 2)).reason, "Duplicate", "older seq")
		-- A rejected-but-well-formed request still burns its sequence number.
		TestUtil.assertEqual(SwingValidator.validate(state, request(6, EPOCH + 2.1), context(EPOCH + 2)).reason, "FutureTimestamp", "future")
		TestUtil.assertEqual(SwingValidator.validate(state, request(6, EPOCH + 3), context(EPOCH + 3)).reason, "Duplicate", "replay after reject")
	end)

	t.test("invalid client input is rejected without side effects", function()
		local nan = 0 / 0
		local bad: { { any } } = {
			{ nil, EPOCH, 0, 1 },
			{ "1", EPOCH, 0, 1 },
			{ 1, "now", 0, 1 },
			{ 1, EPOCH, nan, 1 },
			{ 1, EPOCH, 0, math.huge },
			{ 1, -math.huge, 0, 1 },
			{ 0, EPOCH, 0, 1 },
			{ -4, EPOCH, 0, 1 },
			{ 1.5, EPOCH, 0, 1 },
			{ 2 ^ 40, EPOCH, 0, 1 },
			{ 1, EPOCH, { 1 }, 1 },
			{ 1, EPOCH, 0, 1e9 },
			{ 1, EPOCH, Vector3.zero, 1 },
		}
		local state = SwingValidator.newState()
		for i, args in bad do
			local parsed = SwingValidator.parse(args[1], args[2], args[3], args[4], nil)
			TestUtil.assertTrue(parsed == nil, `bad input {i} parsed`)
			TestUtil.assertEqual(SwingValidator.validate(state, parsed, context(EPOCH)).reason, "InvalidInput", `bad input {i}`)
		end
		TestUtil.assertTrue(SwingValidator.parse(1, EPOCH, 0, 1, "x") == nil, "non-numeric pitch id")
		TestUtil.assertEqual(state.lastSeq, 0, "invalid input must not consume sequence numbers")
		TestUtil.assertTrue(SwingValidator.validate(state, request(1, EPOCH), context(EPOCH)).accepted, "valid after invalid")
	end)

	t.test("aim outside the hitting region is rejected", function()
		local geometry = TestUtil.geometries().straight
		local minX, maxX, minY, maxY = SwingModel.aimBounds(geometry)
		local slack = units.toStuds(BattingConfig.Aim.ValidationToleranceMeters)
		local cases: { { any } } = {
			{ maxX + slack * 2, AIM_Y, false },
			{ minX - slack * 2, AIM_Y, false },
			{ AIM_X, maxY + slack * 2, false },
			{ AIM_X, minY - slack * 2, false },
			{ maxX + slack * 0.5, maxY, true }, -- float noise at the edge is fine
			{ minX, minY, true },
		}
		for i, case in cases do
			local state = SwingValidator.newState()
			local v = SwingValidator.validate(state, request(1, EPOCH, case[1], case[2]), context(EPOCH))
			TestUtil.assertEqual(v.accepted, case[3], `aim case {i} ({v.reason})`)
			if not case[3] then
				TestUtil.assertEqual(v.reason, "AimOutOfBounds", `aim case {i} reason`)
			end
		end
	end)

	t.test("latency compensation is bounded by ping and by a hard cap", function()
		local net = BattingConfig.Network
		-- Normal latency: rewound exactly.
		local state = SwingValidator.newState()
		local v = SwingValidator.validate(state, request(1, EPOCH - 0.1), context(EPOCH, { ping = 0.1 }))
		TestUtil.assertTrue(v.accepted and not v.clamped, "100 ms rewind at 100 ms ping")
		TestUtil.assertNear(v.rewind :: number, 0.1, 1e-6, "rewind")

		-- Claiming more rewind than the ping justifies: clamped forward.
		state = SwingValidator.newState()
		v = SwingValidator.validate(state, request(1, EPOCH - 0.3), context(EPOCH, { ping = 0.05 }))
		local allowed = 0.05 * net.PingRewindFactor + net.RewindSlackSeconds
		TestUtil.assertTrue(v.accepted and v.clamped, "excess rewind should clamp")
		TestUtil.assertNear(v.effectiveTime :: number, EPOCH - allowed, 1e-6, "clamped to the ping allowance")

		-- Huge ping: allowance capped.
		TestUtil.assertNear(SwingValidator.allowedRewind(2.0), net.MaxRewindSeconds, 1e-9, "rewind cap")
		state = SwingValidator.newState()
		v = SwingValidator.validate(state, request(1, EPOCH - 0.6), context(EPOCH, { ping = 2.0 }))
		TestUtil.assertNear(v.rewind :: number, net.MaxRewindSeconds, 1e-6, "high ping rewind capped")
		-- Garbage ping values fall back to the slack only.
		TestUtil.assertNear(SwingValidator.allowedRewind(0 / 0), net.RewindSlackSeconds, 1e-9, "NaN ping")
		TestUtil.assertNear(SwingValidator.allowedRewind(-1), net.RewindSlackSeconds, 1e-9, "negative ping")

		-- Very old stamps are rejected, not clamped.
		state = SwingValidator.newState()
		v = SwingValidator.validate(state, request(1, EPOCH - net.StaleRejectSeconds - 0.1), context(EPOCH))
		TestUtil.assertEqual(v.reason, "StaleTimestamp", "stale")

		-- Future stamps: tiny clock noise tolerated (clamped to now), beyond that rejected.
		state = SwingValidator.newState()
		v = SwingValidator.validate(state, request(1, EPOCH + net.FutureToleranceSeconds * 0.5), context(EPOCH))
		TestUtil.assertTrue(v.accepted, "clock noise rejected")
		TestUtil.assertEqual(v.effectiveTime, EPOCH, "future noise clamped to receive time")
		state = SwingValidator.newState()
		v = SwingValidator.validate(state, request(1, EPOCH + net.FutureToleranceSeconds * 2), context(EPOCH))
		TestUtil.assertEqual(v.reason, "FutureTimestamp", "future")
	end)

	t.test("swing spam is limited by the cooldown and the flood guard", function()
		local state = SwingValidator.newState()
		TestUtil.assertTrue(SwingValidator.validate(state, request(1, EPOCH), context(EPOCH, { pitch = false })).accepted, "first")
		-- Flood: another request a few ms later.
		TestUtil.assertEqual(SwingValidator.validate(state, request(2, EPOCH + 0.01), context(EPOCH + 0.01, { pitch = false })).reason, "RateLimited", "flood")
		-- Inside the swing cycle.
		TestUtil.assertEqual(SwingValidator.validate(state, request(3, EPOCH + CYCLE * 0.5), context(EPOCH + CYCLE * 0.5, { pitch = false })).reason, "Cooldown", "cooldown")
		-- A client can't dodge the cooldown by back-dating (rewind is bounded).
		TestUtil.assertEqual(
			SwingValidator.validate(state, request(4, EPOCH + CYCLE + 0.3), context(EPOCH + CYCLE + 0.3, { pitch = false })).accepted,
			true,
			"after cycle"
		)
		local backdated = SwingValidator.validate(state, request(5, EPOCH + CYCLE + 0.3), context(EPOCH + CYCLE + 0.5, { pitch = false }))
		TestUtil.assertEqual(backdated.reason, "Cooldown", "back-to-back after clamp")
	end)

	t.test("one swing per pitch; swings outside the flight are practice swings", function()
		local state = SwingValidator.newState()
		local pitch = { id = 7, releaseTime = EPOCH + 1, endTime = EPOCH + 1.8 }
		-- Before release (whole Active window ends before the ball leaves the hand).
		local practice = SwingValidator.validate(state, request(1, EPOCH), context(EPOCH, { pitch = pitch }))
		TestUtil.assertEqual(practice.reason, "PracticeSwing", "early practice swing")
		TestUtil.assertTrue(practice.accepted and practice.pitchId == nil, "practice swing should not consume the pitch")
		-- Real swing at the pitch.
		local real = SwingValidator.validate(state, request(2, EPOCH + 1.5), context(EPOCH + 1.5, { pitch = pitch }))
		TestUtil.assertTrue(real.accepted and real.pitchId == 7, `real swing ({real.reason})`)
		-- A second swing at the same pitch after the cooldown is refused.
		local t2 = EPOCH + 1.5 + CYCLE + 0.01
		local pitchLong = { id = 7, releaseTime = EPOCH + 1, endTime = EPOCH + 10 }
		TestUtil.assertEqual(SwingValidator.validate(state, request(3, t2), context(t2, { pitch = pitchLong })).reason, "AlreadySwung", "second swing")
		-- The next pitch can be swung at again.
		local t3 = t2 + CYCLE + 0.01
		local nextPitch = { id = 8, releaseTime = t3 - 0.2, endTime = t3 + 0.6 }
		TestUtil.assertEqual(SwingValidator.validate(state, request(4, t3), context(t3, { pitch = nextPitch })).pitchId, 8, "next pitch")
	end)

	t.test("players without a lane cannot swing", function()
		local state = SwingValidator.newState()
		TestUtil.assertEqual(SwingValidator.validate(state, request(1, EPOCH), context(EPOCH, { geometry = false })).reason, "NoLane", "no lane")
	end)
end
