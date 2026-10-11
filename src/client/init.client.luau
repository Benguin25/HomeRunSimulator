--!strict
-- Client entry point: pitch rendering, batting camera, batting and (Studio) debug overlay.

local BattingCamera = require(script.BattingCamera)
local BattingController = require(script.BattingController)
local PitchDebugView = require(script.PitchDebugView)
local PitchVisualController = require(script.PitchVisualController)

PitchVisualController.start()
BattingCamera.start()
PitchDebugView.start()
BattingController.start()
