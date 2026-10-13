--!strict
-- Shared client audio mixer. Failed custom assets fall back once, never block play.
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Presentation.PresentationConfig).Sounds
local Audio = {}
type Spec = { Id: string, Volume: number, Speed: number, Fallback: string? }
local sounds: { [string]: Sound } = {}
local last: { [string]: number } = {}
local group: SoundGroup?
local function configure(sound: Sound, spec: Spec)
	sound.SoundId, sound.Volume, sound.PlaybackSpeed = spec.Id, spec.Volume * Config.MasterVolume, spec.Speed
	sound.SoundGroup = group
	task.spawn(function()
		local failed = false
		local ok = pcall(function()
			ContentProvider:PreloadAsync({ sound }, function(_, status)
				if status ~= Enum.AssetFetchStatus.Success then
					failed = true
				end
			end)
		end)
		if (not ok or failed) and sound.Parent and spec.Fallback and spec.Fallback ~= "" then
			sound.SoundId = spec.Fallback
		end
	end)
end
function Audio.play(key: string, gain: number?)
	local spec = (Config :: any)[key] :: Spec?
	if not spec or spec.Id == "" then
		return
	end
	local now = os.clock()
	if now - (last[key] or -math.huge) < Config.MinGapSeconds then
		return
	end
	last[key] = now
	if not sounds[key] then
		local created = Instance.new("Sound")
		created.Name, created.Parent = "HomeRun_" .. key, SoundService
		configure(created, spec)
		sounds[key] = created
	end
	local sound = sounds[key]
	local playing = 0
	for _, other in sounds do
		if other.IsPlaying then
			playing += 1
		end
	end
	if playing >= Config.MaxConcurrent then
		-- At most a few short cues; newer feedback replaces the oldest playing cue.
		local oldestKey, oldestAt = "", math.huge
		for name, other in sounds do
			if other.IsPlaying and (last[name] or 0) < oldestAt then
				oldestKey, oldestAt = name, last[name] or 0
			end
		end
		if sounds[oldestKey] then
			sounds[oldestKey]:Stop()
		end
	end
	sound.Volume = math.clamp(spec.Volume * Config.MasterVolume * (gain or 1), 0, 1)
	sound:Stop()
	sound.TimePosition = 0
	sound:Play()
end
function Audio.attachWhoosh(part: BasePart?)
	local spec = Config.Whoosh
	if not part or spec.Id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name, sound.Looped, sound.RollOffMaxDistance = "FlightWhoosh", true, 200
	sound.Parent = part
	configure(sound, spec :: any)
	sound:Play() -- destroyed with the ball; off by default until a suitable licensed loop is configured
end
function Audio.clear()
	for _, sound in sounds do
		sound:Stop()
	end
end
function Audio.start()
	local mixer = Instance.new("SoundGroup")
	mixer.Name, mixer.Volume, mixer.Parent = "HomeRunFeedback", 1, SoundService
	group = mixer
	game:GetService("Players").LocalPlayer:GetAttributeChangedSignal("PitchLaneId"):Connect(Audio.clear)
end
return Audio
