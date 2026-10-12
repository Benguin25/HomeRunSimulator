--!strict
-- Unit conversions between real-world measurements and Roblox studs.
--
-- All pitching physics runs in studs and seconds. Every real-world number in
-- PitchConfig is authored in SI units (meters, kilograms, m/s) or mph and is
-- converted exactly once through this module.
--
-- Scale convention (default): 1 stud = 0.28 m, the scale Roblox documents for
-- its default characters. Note that Workspace.Gravity (196.2 studs/s^2) does
-- NOT match that scale (it would be ~55 m/s^2), which is one reason pitches use
-- their own gravity instead of Workspace.Gravity.
-- If the stadium was built to a different scale, change
-- PitchConfig.Units.MetersPerStud and every derived value follows.

local Units = {}

Units.METERS_PER_MILE = 1609.344
Units.SECONDS_PER_HOUR = 3600
Units.MPH_TO_MPS = Units.METERS_PER_MILE / Units.SECONDS_PER_HOUR -- 0.44704
Units.RPM_TO_RAD_PER_SEC = (2 * math.pi) / 60
Units.METERS_PER_FOOT = 0.3048

export type Converter = {
	metersPerStud: number,
	studsPerMeter: number,
	toStuds: (meters: number) -> number,
	toMeters: (studs: number) -> number,
	mphToStudsPerSecond: (mph: number) -> number,
	studsPerSecondToMph: (studsPerSecond: number) -> number,
	-- Acceleration in m/s^2 -> studs/s^2
	accelToStuds: (metersPerSecondSq: number) -> number,
}

function Units.new(metersPerStud: number): Converter
	assert(metersPerStud > 0, "metersPerStud must be positive")
	local studsPerMeter = 1 / metersPerStud
	return {
		metersPerStud = metersPerStud,
		studsPerMeter = studsPerMeter,
		toStuds = function(meters: number): number
			return meters * studsPerMeter
		end,
		toMeters = function(studs: number): number
			return studs * metersPerStud
		end,
		mphToStudsPerSecond = function(mph: number): number
			return mph * Units.MPH_TO_MPS * studsPerMeter
		end,
		studsPerSecondToMph = function(studsPerSecond: number): number
			return studsPerSecond * metersPerStud / Units.MPH_TO_MPS
		end,
		accelToStuds = function(metersPerSecondSq: number): number
			return metersPerSecondSq * studsPerMeter
		end,
	}
end

return Units
