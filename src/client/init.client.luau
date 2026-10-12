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

PitchVisualController.start()
BattingCamera.start()
PitchDebugView.start()
HitEffects.start()
HitHud.start()
BattedBallController.start()
BattingController.start()
