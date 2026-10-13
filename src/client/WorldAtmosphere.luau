--!strict
-- Client-only grading: another player's world never changes your lighting.
-- Rookie Park gets the Stage 2 afternoon look (EnvironmentConfig.Lighting);
-- every property touched is captured once and restored on world change.
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Worlds.WorldConfig)
local EnvConfig = require(Shared.Environment.EnvironmentConfig)
local Environment = {}

local function color(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

-- Chooses the candidate ClockTime/latitude whose real engine sun direction is
-- behind and above the batter (never in the batter's eyes).
local function pickSun(forward: Vector3): (number, number)
	local cfg = EnvConfig.Lighting
	local bestScore, bestTime, bestLat = -math.huge, Lighting.ClockTime, Lighting.GeographicLatitude
	for _, c in cfg.SunCandidates do
		Lighting.ClockTime, Lighting.GeographicLatitude = c.ClockTime, c.GeographicLatitude
		local sun = Lighting:GetSunDirection()
		local behind = sun:Dot(-forward)
		local elevation = math.deg(math.asin(math.clamp(sun.Y, -1, 1)))
		local score = behind - math.abs(elevation - cfg.TargetElevationDegrees) / 60
		if score > bestScore then
			bestScore, bestTime, bestLat = score, c.ClockTime, c.GeographicLatitude
		end
	end
	return bestTime, bestLat
end

function Environment.start()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	local rays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
	local saved = {
		ClockTime = Lighting.ClockTime,
		GeographicLatitude = Lighting.GeographicLatitude,
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogStart = Lighting.FogStart,
		FogEnd = Lighting.FogEnd,
		FogColor = Lighting.FogColor,
		ExposureCompensation = Lighting.ExposureCompensation,
		EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
		EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
		ShadowSoftness = Lighting.ShadowSoftness,
	}
	local savedAtmosphere = atmosphere
		and {
			Density = atmosphere.Density,
			Offset = atmosphere.Offset,
			Color = atmosphere.Color,
			Decay = atmosphere.Decay,
			Glare = atmosphere.Glare,
			Haze = atmosphere.Haze,
		}
	local savedBloom = bloom and { Intensity = bloom.Intensity, Size = bloom.Size, Threshold = bloom.Threshold }
	local savedRays = rays and { Intensity = rays.Intensity, Spread = rays.Spread }
	local savedDof = dof
		and {
			FarIntensity = dof.FarIntensity,
			FocusDistance = dof.FocusDistance,
			InFocusRadius = dof.InFocusRadius,
			NearIntensity = dof.NearIntensity,
		}
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name, grade.Parent = "WorldGrade", Lighting
	local rookieSun: { number }? = nil
	local function restore()
		for key, value in saved do
			(Lighting :: any)[key] = value
		end
		grade.TintColor, grade.Contrast, grade.Saturation, grade.Brightness = Color3.new(1, 1, 1), 0, 0, 0
		if atmosphere and savedAtmosphere then
			for key, value in savedAtmosphere do
				(atmosphere :: any)[key] = value
			end
		end
		if bloom and savedBloom then
			bloom.Intensity, bloom.Size, bloom.Threshold = savedBloom.Intensity, savedBloom.Size, savedBloom.Threshold
		end
		if rays and savedRays then
			rays.Intensity, rays.Spread = savedRays.Intensity, savedRays.Spread
		end
		if dof and savedDof then
			for key, value in savedDof do
				(dof :: any)[key] = value
			end
		end
	end
	local function applyRookie()
		local cfg = EnvConfig.Lighting
		if not rookieSun then
			local t, lat = pickSun(EnvConfig.Site.Forward.Unit)
			rookieSun = { t, lat }
		end
		local sun = rookieSun :: { number }
		Lighting.ClockTime, Lighting.GeographicLatitude = sun[1], sun[2]
		Lighting.Brightness = cfg.Brightness
		Lighting.Ambient, Lighting.OutdoorAmbient = color(cfg.Ambient), color(cfg.OutdoorAmbient)
		Lighting.ExposureCompensation = cfg.ExposureCompensation
		Lighting.EnvironmentDiffuseScale = cfg.EnvironmentDiffuseScale
		Lighting.EnvironmentSpecularScale = cfg.EnvironmentSpecularScale
		Lighting.ShadowSoftness = cfg.ShadowSoftness
		Lighting.FogStart, Lighting.FogEnd = cfg.FogStart, cfg.FogEnd
		grade.TintColor, grade.Contrast = color(cfg.Grade.Tint), cfg.Grade.Contrast
		grade.Saturation, grade.Brightness = cfg.Grade.Saturation, cfg.Grade.Brightness
		if atmosphere then
			local a = cfg.Atmosphere
			atmosphere.Density, atmosphere.Offset = a.Density, a.Offset
			atmosphere.Color, atmosphere.Decay = color(a.Color), color(a.Decay)
			atmosphere.Glare, atmosphere.Haze = a.Glare, a.Haze
		end
		if bloom then
			bloom.Intensity, bloom.Size, bloom.Threshold = cfg.Bloom.Intensity, cfg.Bloom.Size, cfg.Bloom.Threshold
		end
		if rays then
			rays.Intensity, rays.Spread = cfg.SunRays.Intensity, cfg.SunRays.Spread
		end
		if dof then
			local d = cfg.DepthOfField
			dof.FarIntensity, dof.FocusDistance = d.FarIntensity, d.FocusDistance
			dof.InFocusRadius, dof.NearIntensity = d.InFocusRadius, d.NearIntensity
		end
	end
	local function update()
		restore()
		local id = Players.LocalPlayer:GetAttribute("CurrentWorld")
		local cfg = if id == "power"
			then Config.Environment.power
			elseif id == "sky" then Config.Environment.sky
			else nil
		if cfg then
			Lighting.ClockTime, Lighting.Brightness = cfg.ClockTime, cfg.Brightness
			Lighting.Ambient, Lighting.OutdoorAmbient = color(cfg.Ambient), color(cfg.OutdoorAmbient)
			Lighting.FogStart, Lighting.FogEnd, Lighting.FogColor = cfg.FogStart, cfg.FogEnd, color(cfg.FogColor)
			grade.TintColor, grade.Contrast, grade.Saturation = color(cfg.Tint), cfg.Contrast, cfg.Saturation
			if atmosphere then
				atmosphere.Density = cfg.AtmosphereDensity
			end
		elseif EnvConfig.Enabled then
			applyRookie()
		end
	end
	Players.LocalPlayer:GetAttributeChangedSignal("CurrentWorld"):Connect(update)
	update()
end
return Environment
