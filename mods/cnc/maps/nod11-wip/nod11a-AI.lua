---comment
---@param shapeX integer
---@param shapeY integer
---@param actor actor?
---@param type string?
---@param location cpos?
---@param onBuilt fun(actor: actor)?
local function SetBlueprint(shapeX, shapeY, actor, type, location, onBuilt)
end

local function SetGDIBlueprints()
	SetBlueprint(2, 3, MainBasePower1)
	SetBlueprint(2, 3, MainBasePower1)
	SetBlueprint(2, 3, MainBasePower5, nil, CPos.New(53, 7))
	SetBlueprint(2, 3, MainBasePower4)
	SetBlueprint(3, 4, MainBaseRefinery, nil, CPos.New(45, 7))
	SetBlueprint(2, 3, MainBaseHeadquarters)
	SetBlueprint(3, 3, MainBaseFactory)
	SetBlueprint(2, 3, MainBaseBarracks)
	SetBlueprint(2, 1, Silo3)
	SetBlueprint(2, 1, Silo2)
	SetBlueprint(2, 1, Silo4)
	SetBlueprint(2, 1, Silo1)
	SetBlueprint(1, 1, MainBaseTower1)
	SetBlueprint(1, 1, MainBaseTower2)
	SetBlueprint(2, 3, MainBasePower2)
	SetBlueprint(2, 3, MainBasePower3)
	SetBlueprint(1, 1, MainBaseTower1)
	SetBlueprint(1, 1, MainBaseTower2)
end

ActivateAI = function()
	Media.Debug("GDI activation done.")
end
