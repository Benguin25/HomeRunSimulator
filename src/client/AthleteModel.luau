--!strict
-- Builds and draws one procedural athlete (pitcher or catcher) from the
-- AthleteRig skeleton: R15-named anchored parts plus uniform/gear pieces,
-- moved together each frame with one BulkMoveTo. Uses only built-in part
-- shapes, SpecialMesh primitives and the client's own default face texture:
-- no animation or mesh asset IDs. Nothing collides, touches or is raycast.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local AthleteConfig = require(Shared.Presentation.AthleteConfig)
local AthleteRig = require(Shared.Presentation.AthleteRig)

local AthleteModel = {}
AthleteModel.__index = AthleteModel

export type Kind = "Pitcher" | "Catcher"

type Piece = { part: BasePart, bone: string, offset: CFrame, mitt: boolean, decal: Decal? }

export type AthleteModel = typeof(setmetatable(
	{} :: {
		model: Model,
		pieces: { Piece },
		list: { BasePart },
		cframes: { CFrame },
		transparency: number,
		mittTransparency: number,
	},
	AthleteModel
))

local colors = AthleteConfig.Colors

local function rgb(name: string): Color3
	local c = (colors :: any)[name] :: { number }
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function newPart(model: Model, name: string, size: Vector3, color: string, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape or Enum.PartType.Block
	part.Size = size
	part.Color = rgb(color)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface, part.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, false, false, false
	part.Massless = true
	part.Parent = model
	return part
end

local function mesh(part: BasePart, kind: Enum.MeshType)
	local m = Instance.new("SpecialMesh")
	m.MeshType = kind
	m.Parent = part
end

local BODY_COLOR: { [string]: string } = {
	LowerTorso = "Pants",
	UpperTorso = "Jersey",
	UpperArm = "Jersey",
	LowerArm = "Skin",
	Hand = "Skin",
	UpperLeg = "Pants",
	LowerLeg = "Socks",
	Foot = "Cleats",
}

local function bodyColor(name: string): string
	for suffix, color in BODY_COLOR do
		if string.sub(name, -#suffix) == suffix then
			return color
		end
	end
	return "Jersey"
end

function AthleteModel.new(kind: Kind, skeleton: AthleteRig.Skeleton, gloveSide: "Right" | "Left", parent: Instance): AthleteModel
	local model = Instance.new("Model")
	model.Name = kind
	local pieces: { Piece } = {}
	-- Accessory sizes are authored for the reference rig; k scales them.
	local k = skeleton.parts.Head.size.Y
	local function add(part: BasePart, bone: string, offset: CFrame?, isMitt: boolean?, decal: Decal?)
		table.insert(pieces, { part = part, bone = bone, offset = offset or CFrame.identity, mitt = isMitt == true, decal = decal })
	end

	for _, name in skeleton.order do
		local def = skeleton.parts[name]
		if name == "Head" then
			-- Classic rounded head: an upright cylinder.
			local head = newPart(model, name, Vector3.new(def.size.Y, def.size.X, def.size.Z), "Skin", Enum.PartType.Cylinder)
			add(head, name, CFrame.Angles(0, 0, math.pi / 2))
		else
			add(newPart(model, name, def.size, bodyColor(name)), name)
		end
	end

	-- Face: the client's built-in default face on an invisible plate.
	local plate = newPart(model, "FacePlate", Vector3.new(0.62, 0.62, 0.02) * k, "Skin")
	plate.Transparency = 1
	local face = Instance.new("Decal")
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = plate
	add(plate, "Head", CFrame.new(0, -0.02 * k, -0.48 * k), false, face)

	-- Belt and jersey trim.
	add(newPart(model, "Belt", Vector3.new(1.38, 0.1, 0.83) * k, "Belt"), "LowerTorso", CFrame.new(0, 0.3 * k, 0))
	for _, side in { "Right", "Left" } do
		add(
			newPart(model, side .. "SleeveTrim", Vector3.new(0.56, 0.08, 0.56) * k, "JerseyTrim"),
			side .. "UpperArm",
			CFrame.new(0, -0.5 * k, 0)
		)
	end

	local glove = gloveSide .. "Hand"
	if kind == "Pitcher" then
		local crown = newPart(model, "CapCrown", Vector3.new(1.02, 0.56, 1.02) * k, "Cap")
		mesh(crown, Enum.MeshType.Sphere)
		add(crown, "Head", CFrame.new(0, 0.34 * k, 0.02 * k))
		local bill = newPart(model, "CapBill", Vector3.new(0.78, 0.06, 0.42) * k, "Cap")
		add(bill, "Head", CFrame.new(0, 0.3 * k, -0.62 * k) * CFrame.Angles(math.rad(-8), 0, 0))
		local mitt = newPart(model, "Glove", Vector3.new(0.62, 0.78, 0.4) * k, "Glove")
		mesh(mitt, Enum.MeshType.Sphere)
		add(mitt, glove, CFrame.new(0, -0.14 * k, -0.04 * k), true)
		local web = newPart(model, "GloveWeb", Vector3.new(0.3, 0.3, 0.1) * k, "GloveLace")
		add(web, glove, CFrame.new(0, -0.38 * k, -0.18 * k), true)
		-- Jersey number on the back.
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Back
		gui.CanvasSize = Vector2.new(200, 200)
		gui.LightInfluence = 1
		local number = Instance.new("TextLabel")
		number.BackgroundTransparency = 1
		number.Size = UDim2.fromScale(1, 0.8)
		number.Position = UDim2.fromScale(0, 0.1)
		number.Font = Enum.Font.GothamBlack
		number.TextScaled = true
		number.TextColor3 = rgb("JerseyTrim")
		number.Text = AthleteConfig.PitcherNumber
		number.Parent = gui
		for _, piece in pieces do
			if piece.bone == "UpperTorso" and piece.part.Name == "UpperTorso" then
				gui.Parent = piece.part
			end
		end
	else
		local helmet = newPart(model, "Helmet", Vector3.new(1.08, 0.7, 1.12) * k, "CatcherGear")
		mesh(helmet, Enum.MeshType.Sphere)
		add(helmet, "Head", CFrame.new(0, 0.3 * k, 0.04 * k))
		local mask = newPart(model, "Mask", Vector3.new(0.86, 0.9, 0.12) * k, "Mask")
		mask.Transparency = 0.35
		add(mask, "Head", CFrame.new(0, -0.02 * k, -0.56 * k))
		for i = -1, 1 do
			add(
				newPart(model, `MaskBar{i + 2}`, Vector3.new(0.88, 0.05, 0.06) * k, "Mask"),
				"Head",
				CFrame.new(0, i * 0.24 * k, -0.62 * k)
			)
		end
		add(newPart(model, "ChestProtector", Vector3.new(1.55, 1.6, 0.18) * k, "CatcherGear"), "UpperTorso", CFrame.new(0, -0.02 * k, -0.52 * k))
		for _, side in { "Right", "Left" } do
			add(
				newPart(model, side .. "ShinGuard", Vector3.new(0.62, 1.55, 0.2) * k, "CatcherGear"),
				side .. "LowerLeg",
				CFrame.new(0, 0, -0.32 * k)
			)
		end
		local mitt = newPart(model, "Mitt", Vector3.new(0.86, 0.9, 0.42) * k, "Glove")
		mesh(mitt, Enum.MeshType.Sphere)
		add(mitt, glove, CFrame.new(0, -0.18 * k, -0.08 * k), true)
		local pocket = newPart(model, "MittPocket", Vector3.new(0.5, 0.5, 0.06) * k, "GloveLace")
		mesh(pocket, Enum.MeshType.Sphere)
		add(pocket, glove, CFrame.new(0, -0.2 * k, -0.3 * k), true)
	end

	local list = table.create(#pieces)
	for i, piece in pieces do
		list[i] = piece.part
	end
	model.Parent = parent
	return setmetatable({
		model = model,
		pieces = pieces,
		list = list,
		cframes = table.create(#pieces, CFrame.identity),
		transparency = 0,
		mittTransparency = 0,
	}, AthleteModel)
end

function AthleteModel.render(self: AthleteModel, cframes: { [string]: CFrame })
	local out = self.cframes
	for i, piece in self.pieces do
		local bone = cframes[piece.bone]
		out[i] = if bone then bone * piece.offset else out[i]
	end
	workspace:BulkMoveTo(self.list, out, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Local fade (the catcher in front of the batter's own camera).
function AthleteModel.setTransparency(self: AthleteModel, body: number, mitt: number)
	if math.abs(body - self.transparency) < 1e-3 and math.abs(mitt - self.mittTransparency) < 1e-3 then
		return
	end
	self.transparency, self.mittTransparency = body, mitt
	for _, piece in self.pieces do
		local value = if piece.mitt then mitt else body
		if piece.decal then
			piece.decal.Transparency = value
		elseif piece.part.Name == "Mask" then
			piece.part.Transparency = math.max(value, 0.35)
		else
			piece.part.Transparency = value
		end
	end
end

function AthleteModel.setParent(self: AthleteModel, parent: Instance?)
	if self.model.Parent ~= parent then
		self.model.Parent = parent
	end
end

function AthleteModel.destroy(self: AthleteModel)
	self.model:Destroy()
	table.clear(self.pieces)
	table.clear(self.list)
end

return AthleteModel
