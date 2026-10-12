--!strict
-- Client-only grading: another player's world never changes your lighting.
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Worlds.WorldConfig)
local Environment = {}
function Environment.start()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	local originalDensity = if atmosphere then atmosphere.Density else 0
	local saved = {
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogStart = Lighting.FogStart,
		FogEnd = Lighting.FogEnd,
		FogColor = Lighting.FogColor,
	}
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name, grade.Parent = "WorldGrade", Lighting
	local function update()
		Lighting.ClockTime, Lighting.Brightness = saved.ClockTime, saved.Brightness
		Lighting.Ambient, Lighting.OutdoorAmbient = saved.Ambient, saved.OutdoorAmbient
		Lighting.FogStart, Lighting.FogEnd, Lighting.FogColor = saved.FogStart, saved.FogEnd, saved.FogColor
		grade.TintColor, grade.Contrast, grade.Saturation = Color3.new(1, 1, 1), 0, 0
		if atmosphere then
			atmosphere.Density = originalDensity
		end
		local id = Players.LocalPlayer:GetAttribute("CurrentWorld")
		local cfg = if id == "power"
			then Config.Environment.power
			elseif id == "sky" then Config.Environment.sky
			else nil
		if cfg then
			local function color(values: { number }): Color3
				return Color3.fromRGB(values[1], values[2], values[3])
			end
			Lighting.ClockTime, Lighting.Brightness = cfg.ClockTime, cfg.Brightness
			Lighting.Ambient, Lighting.OutdoorAmbient = color(cfg.Ambient), color(cfg.OutdoorAmbient)
			Lighting.FogStart, Lighting.FogEnd, Lighting.FogColor = cfg.FogStart, cfg.FogEnd, color(cfg.FogColor)
			grade.TintColor, grade.Contrast, grade.Saturation = color(cfg.Tint), cfg.Contrast, cfg.Saturation
			if atmosphere then
				atmosphere.Density = cfg.AtmosphereDensity
			end
		end
	end
	Players.LocalPlayer:GetAttributeChangedSignal("CurrentWorld"):Connect(update)
	update()
end
return Environment
