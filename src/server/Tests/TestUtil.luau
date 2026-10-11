--!strict
-- Helpers shared by the pitching specs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Pitching = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Pitching")
local LaneGeometry = require(Pitching.LaneGeometry)
local PitchConfig = require(Pitching.PitchConfig)
local Units = require(Pitching.Units)

local TestUtil = {}

-- Deterministic RNG with the same NextNumber signature as Roblox's Random,
-- so results are identical in Studio and in the CLI.
export type FakeRandom = {
	state: number,
	NextNumber: (self: FakeRandom, min: number, max: number) -> number,
}

function TestUtil.rng(seed: number): FakeRandom
	local rng = {
		state = seed % 2147483647,
		NextNumber = function(self: FakeRandom, min: number, max: number): number
			-- Park-Miller minimal standard generator.
			self.state = (self.state * 48271) % 2147483647
			return min + (max - min) * (self.state / 2147483647)
		end,
	}
	if rng.state <= 0 then
		rng.state += 2147483646
	end
	return rng
end

TestUtil.units = Units.new(PitchConfig.Units.MetersPerStud)

-- A straight lane along -Z at the origin, and a rotated, elevated one to
-- prove nothing depends on world axes.
function TestUtil.geometries(): { [string]: LaneGeometry.Geometry }
	local distance = TestUtil.units.toStuds(PitchConfig.Geometry.MoundToPlateMeters)
	local diagonal = Vector3.new(1, 0, 0.6).Unit
	local elevatedPlate = Vector3.new(250, 37.5, -120)
	return {
		straight = LaneGeometry.new({
			plateGround = Vector3.zero,
			pitcherGround = Vector3.new(0, 0.7, -distance),
		}),
		rotated = LaneGeometry.new({
			plateGround = elevatedPlate,
			pitcherGround = elevatedPlate + diagonal * distance + Vector3.new(0, 0.7, 0),
		}),
	}
end

function TestUtil.assertNear(actual: number, expected: number, tolerance: number, message: string?)
	if math.abs(actual - expected) > tolerance then
		error(
			string.format("%s: expected %.6f +/- %.6f, got %.6f", message or "assertNear", expected, tolerance, actual),
			2
		)
	end
end

function TestUtil.assertTrue(value: any, message: string?)
	if not value then
		error(message or "expected truthy value", 2)
	end
end

function TestUtil.assertEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "assertEqual"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

return TestUtil
