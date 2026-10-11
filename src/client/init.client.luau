--!strict
-- Client entry point: pitch rendering, batting camera and (Studio) debug overlay.

local BattingCamera = require(script.BattingCamera)
local PitchDebugView = require(script.PitchDebugView)
local PitchVisualController = require(script.PitchVisualController)

PitchVisualController.start()
BattingCamera.start()
PitchDebugView.start()
