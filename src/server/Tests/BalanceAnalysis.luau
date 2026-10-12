--!strict
-- Deterministic stratified input grids, not an estimate of real player skill.
-- Uses real generated pitches and swept contacts; carry is obstacle-free,
-- plate-level projection. Resolve each contact once for every tuning profile.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local BattedBall = require(Shared.BattedBall.BattedBall)
local Config = require(Shared.BattedBall.BattedBallConfig)
local FieldFrame = require(Shared.BattedBall.FieldFrame)
local ImpactModel = require(Shared.BattedBall.ImpactModel)
local BBTU = require(script.Parent.BattedBallTestUtil)
local TestUtil = require(script.Parent.TestUtil)

local Analysis = {}

local function quantiles(values: {number}): {number}
	table.sort(values)
	local result = {}
	for _, p in {0, 0.1, 0.5, 0.9, 1} do
		table.insert(result, values[math.max(1, math.ceil(#values * p))] or 0)
	end
	return result
end

function Analysis.run(): any
	local original = Config.OriginalBalance
	local profiles: {[string]: ImpactModel.Config} = {
		Original = original,
		Stage5A = Config,
		GeometryOnly = {Impact = Config.Impact, Power = original.Power, ArcadeContact = Config.ArcadeContact},
		PowerOnly = {Impact = Config.Impact, Power = Config.Power, ArcadeContact = original.ArcadeContact},
	}
	local raw: any = {}
	for name in profiles do
		raw[name] = {}
		for _, group in {"Representative", "Solid", "IdealAimSweep"} do
			raw[name][group] = {attempts = 0, ev = {}, launch = {}, carry = {}, over = {0, 0, 0}, types = {0, 0, 0, 0}, labels = {}, best = {carryFeet = -1}}
		end
	end
	local speedMin, speedMax = math.huge, -math.huge
	local targetMin, targetMax = math.huge, -math.huge
	local started = os.clock()
	for _, side in {"Right", "Left"} do
		BBTU.withBatterSide(side, function()
			local geometries = TestUtil.geometries()
			for _, lane in {"straight", "rotated"} do
				local geometry = geometries[lane]
				local frame = FieldFrame.new(geometry)
				for seed = 1, 6 do
					local pitch = BBTU.pitch(geometry, 500 + seed * 37)
					speedMin = math.min(speedMin, pitch.releaseSpeedMph)
					speedMax = math.max(speedMax, pitch.releaseSpeedMph)
					local height = (pitch.data.target - geometry.plateGround):Dot(geometry.up) * frame.metersPerStud
					targetMin, targetMax = math.min(targetMin, height), math.max(targetMax, height)
					local function sample(group: string, dx: number, dy: number, dt: number)
						local contact = BBTU.swing(geometry, pitch, dx, dy, dt).contact
						for name, config in profiles do
							local bucket = raw[name][group]
							bucket.attempts += 1
						if not contact then
							continue
						end
							local launch = BattedBall.computeLaunch(frame, contact, {hitId = 1, laneId = "Test", pitchId = seed, userId = 1}, config)
							local flight = BattedBall.buildFlight(frame, launch)
							local carry = if flight.fieldLanding then flight.fieldLanding.distance / 0.3048 else 0
							if carry > bucket.best.carryFeet then
								bucket.best = {carryFeet = carry, exitMph = flight.exitSpeedMph, launchDegrees = flight.launchAngleDegrees,
									seed = 500 + seed * 37, lane = lane, side = side, dxMeters = dx, dyMeters = dy, dtSeconds = dt, label = contact.label}
							end
							table.insert(bucket.ev, flight.exitSpeedMph)
							table.insert(bucket.launch, flight.launchAngleDegrees)
							table.insert(bucket.carry, carry)
							for i, threshold in {200, 300, 350} do
								if carry > threshold then
									bucket.over[i] += 1
								end
							end
							local angle = flight.launchAngleDegrees
							local kind = if angle < 10 then 1 elseif angle < 25 then 2 elseif angle < 50 then 3 else 4
							bucket.types[kind] += 1
							local label = bucket.labels[contact.label]
							if not label then
								label = {}
								bucket.labels[contact.label] = label
							end
							table.insert(label, carry)
						end
					end
					for _, dx in {-0.15, 0, 0.15} do
						for _, dy in {-0.095, -0.075, -0.055, -0.035, -0.015, 0.005, 0.025, 0.045, 0.065} do
							for _, dt in {-0.07, -0.045, -0.02, 0, 0.02, 0.045, 0.07} do
								sample("Representative", dx, dy, dt)
							end
						end
					end
					for _, dx in {-0.08, 0, 0.08} do
						for _, dy in {-0.06, -0.045, -0.03, -0.015, 0} do
							for _, dt in {-0.02, 0, 0.02} do
								sample("Solid", dx, dy, dt)
							end
						end
					end
					for dy = -0.09, 0.09001, 0.005 do
						sample("IdealAimSweep", 0, dy, 0)
					end
				end
			end
		end)
	end
	local report: any = {quantileOrder = {"min", "p10", "median", "p90", "max"},
		configuration = {contact = Config.ArcadeContact, power = Config.Power},
		inputs = {sides = {"Right", "Left"}, lanes = {"straight", "rotated"}, pitchSeeds = {537, 574, 611, 648, 685, 722},
			representative = {dxMeters = {-0.15, 0, 0.15}, dyMeters = {-0.095, -0.075, -0.055, -0.035, -0.015, 0.005, 0.025, 0.045, 0.065}, dtSeconds = {-0.07, -0.045, -0.02, 0, 0.02, 0.045, 0.07}},
			solid = {dxMeters = {-0.08, 0, 0.08}, dyMeters = {-0.06, -0.045, -0.03, -0.015, 0}, dtSeconds = {-0.02, 0, 0.02}},
			ideal = {dxMeters = 0, dtSeconds = 0, dyMinMeters = -0.09, dyMaxMeters = 0.09, stepMeters = 0.005}},
		overThresholdsFeet = {200, 300, 350}, hitTypes = {"Grounder (<10)", "LineDrive (10–25)", "FlyBall (25–50)", "PopUp (>=50)"},
		pitchSpeedMph = {speedMin, speedMax}, pitchTargetHeightMeters = {targetMin, targetMax}, profiles = {}}
	for name, groups in raw do
		report.profiles[name] = {}
		for group, bucket in groups do
			local count = #bucket.ev
			local function percentages(counts: {number}): {number}
				local result = {}
				for _, value in counts do
					table.insert(result, 100 * value / math.max(1, count))
				end
				return result
			end
			local labels = {}
			for label, carries in bucket.labels do
				labels[label] = {count = #carries, carryFeet = quantiles(carries)}
			end
			report.profiles[name][group] = {attempts = bucket.attempts, contacts = count,
				contactPercent = 100 * count / bucket.attempts, exitMph = quantiles(bucket.ev), launchDegrees = quantiles(bucket.launch),
				carryFeet = quantiles(bucket.carry), overPercentOfContacts = percentages(bucket.over), hitTypePercent = percentages(bucket.types), byLabel = labels, best = bucket.best}
		end
	end
	local geometry = TestUtil.geometries().straight
	local pitch = BBTU.pitch(geometry, 537)
	report.sensitivityDegreesPerCm = {}
	for name, config in profiles do
		local a = BBTU.hit(geometry, pitch, 0, -0.035, 0, config)
		local b = BBTU.hit(geometry, pitch, 0, -0.025, 0, config)
		report.sensitivityDegreesPerCm[name] = a.launchAngleDegrees - b.launchAngleDegrees
	end
	report.verticalSweep = {}
	for dy = -0.085, 0.08501, 0.005 do
		local row: any = {aimCm = dy * 100}
		for name, config in profiles do
			local flight = BBTU.hit(geometry, pitch, 0, dy, 0, config)
			row[name] = {launchDegrees = flight.launchAngleDegrees, exitMph = flight.exitSpeedMph,
				carryFeet = if flight.fieldLanding then flight.fieldLanding.distance / 0.3048 else 0}
		end
		table.insert(report.verticalSweep, row)
	end
	report.elapsedSeconds = os.clock() - started
	return report
end

return Analysis
