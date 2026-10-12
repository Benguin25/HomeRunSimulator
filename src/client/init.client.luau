--!strict
-- Client entry point: pitch rendering, batting / hit camera, batting, batted
-- balls, hit effects and HUD, and the (Studio) debug overlay.

local BattedBallController = require(script.BattedBallController)
local BattingCamera = require(script.BattingCamera)
local BattingController = require(script.BattingController)
local HitEffects = require(script.HitEffects)
local HitHud = require(script.HitHud)
local PitchDebugView = require(script.PitchDebugView)
local PitchVisualController = require(script.PitchVisualController)
local GameplayController = require(script.GameplayController)
local GameplayHud = require(script.GameplayHud)
local ProgressionController = require(script.ProgressionController)
local ProgressionHud = require(script.ProgressionHud)

PitchVisualController.start()
BattingCamera.start()
PitchDebugView.start()
HitEffects.start()
HitHud.start()
ProgressionController.start()
BattedBallController.start()
BattingController.start()
GameplayController.start()
GameplayHud.start()
ProgressionHud.start()
