local GDI = Player.GetPlayer("GDI")
local Nod = Player.GetPlayer("Nod")
local ConstructionYardDiscovered = false
local TechCenterReclaimed = false
local AirstrikeInterval = DateTime.Seconds(510)

local StartingCameraMovement =
{
	Enabled = false,
	--Vector = WVec.New(-1024, -1024, 0),
	Vector = WVec.New(-2048, -2048, 0),
	ExpectedPosition = NodCameraStart.CenterPosition,
	InterruptedTicks = 0,
	InterruptThreshold = 2,
	CutoffY = NodCameraGoal.CenterPosition.Y
}

local CommandoTypes =
{
	easy = "rmbo.easy",
	normal = "rmbo",
	hard = "rmbo.hard"
}

local ReclaimTech = AddPrimaryObjective(Nod, "capture-the-tech-center")

---@type number
local DefendTech

---@type number
local DestroyGDI

---@param actor actor
---@return boolean
local function IsDeadOrIdle(actor)
	return actor.IsDead or actor.IsIdle
end

---@param actor actor
local function IsMobileNod(actor)
	return actor.Owner == Nod and actor.HasProperty("Move")
end

---@param actor actor
local function IsNorthOfRiver(actor)
	return actor.Location.Y < RiverCenter.Location.Y
end

local function MarkNodDead()
	local objs = { ReclaimTech, DestroyGDI }

	Utils.Do(objs, function(obj)
		if Nod.IsObjectiveCompleted(obj) then
			return
		end

		Nod.MarkFailedObjective(obj)
	end)
end

---@param headquarters actor
---@param interval? integer
local function SendAirstrikes(headquarters, interval)
	if headquarters.IsDead or headquarters.Owner ~= GDI then
		return
	end

	interval = interval or AirstrikeInterval
	local target = GetAirstrikeTarget(Nod)

	if target then
		headquarters.TargetAirstrike(target, Angle.SouthWest)
	else
		interval = interval / 4
	end

	Trigger.AfterDelay(interval, function()
		SendAirstrikes(headquarters, interval)
	end)
end

local function PrepareTechObjectives()
	local northTeam = Utils.Where(Nod.GetActors(), function(a)
		return IsMobileNod(a) and IsNorthOfRiver(a)
	end)

	if #northTeam == 0 then
		MarkNodDead()
		return
	end

	Trigger.OnAllKilled(northTeam, function()
		if ConstructionYardDiscovered then
			return
		end

		MarkNodDead()
	end)

	Trigger.OnCapture(TechCenter, function()
		if TechCenterReclaimed then
			return
		end

		TechCenterReclaimed = true
		DestroyGDI = DestroyGDI or AddPrimaryObjective(Nod, "eliminate-gdi-forces")
		Nod.MarkCompletedObjective(ReclaimTech)

		if Difficulty == "hard" then
			DefendTech = DefendTech or AddPrimaryObjective(Nod, "tech-center-survive")
		end
	end)

	Trigger.OnKilled(TechCenter, function()
		if not TechCenterReclaimed then
			Nod.MarkFailedObjective(ReclaimTech)
			return
		end

		if DefendTech then
			Nod.MarkFailedObjective(DefendTech)
		end
	end)
end

--- Order a group to intercept (or chase away) nearby intruders when idle.
--- This is intended to feel similar to GUARD_AREA orders in TD '95.
---@param guards actor[] List of guards.
---@param center wpos Center of the group's search area.
---@param range wdist Radius of the area to guard.
local function GuardArea(guards, center, range)
	guards = Utils.Where(guards, function(g)
		return not g.IsDead
	end)

	if #guards == 0 then
		return
	end

	local activated = false
	local refreshed = false

	Trigger.OnEnteredProximityTrigger(center, range, function(target, id)
		if activated or not IsMobileNod(target) then
			return
		end

		activated = true
		Trigger.RemoveProximityTrigger(id)

		Utils.Do(guards, function(guard)
			if guard.IsDead or not guard.IsIdle then
				return
			end

			guard.AttackMove(target.Location, 2)
			guard.AttackMove(guard.Location)
		end)
	end)

	Utils.Do(guards, function(guard)
		guard.Stance = "Defend"

		Trigger.OnIdle(guard, function()
			-- Does at least one guard remain after an intruder search?
			-- If so, reset the guards and prepare another search area.
			if refreshed or not activated or not Utils.All(guards, IsDeadOrIdle) then
				return
			end

			refreshed = true

			Utils.Do(guards, function(g)
				if g.IsDead then
					return
				end

				Trigger.Clear(g, "OnIdle")
			end)

			Trigger.AfterDelay(10, function()
				GuardArea(guards, center, range)
			end)
		end)
	end)
end

local function OnConstructionYardDiscovered()
	if ConstructionYardDiscovered then
		return
	end

	-- Original had this timer going at the very start.
	Trigger.AfterDelay(AirstrikeInterval, function()
		SendAirstrikes(MainBaseHeadquarters)
	end)

	ConstructionYardDiscovered = true

	if not TechBaseConstructionYard.IsDead then
		TechBaseConstructionYard.Owner = Nod
	end
end

local function PrepareConstructionYardDiscovery()
	Trigger.OnDiscovered(TechBaseConstructionYard, function(_, player)
		if player ~= Nod then
			return
		end

		OnConstructionYardDiscovered()
	end)

	-- Fallback; OnDiscovered will not work if the visibility cheat is on.
	Trigger.OnEnteredProximityTrigger(TechBaseConstructionYard.CenterPosition, WDist.FromCells(5), function(actor, id)
		if ConstructionYardDiscovered then
			Trigger.RemoveProximityTrigger(id)
		end

		if not IsMobileNod(actor) then
			return
		end

		OnConstructionYardDiscovered()
	end)
end

---@param tower actor
local function RevealTechBaseTower(tower)
	if tower.IsDead then
		return
	end

	tower.GrantCondition("revealed")
end

local function PrepareTowerReveals()
	local towers = { TechBaseTower1, TechBaseTower2 }

	Utils.Do(towers, function(tower)
		Trigger.OnEnteredProximityTrigger(tower.CenterPosition, WDist.FromCells(9), function(actor, id)
			if not IsMobileNod(actor) or not IsNorthOfRiver(actor) then
				return
			end

			Trigger.RemoveProximityTrigger(id)
			RevealTechBaseTower(tower)
		end)
	end)
end

local function atk1()
	-- TODO Pre-built infantry should be available by the time this is reached.
	-- From that pool, send "gdi5": x2 E1, x3 E2. WP 1, 7, 11, 9, 8.
end

local function PrepareBasicFootprintTriggers()
	local footprints =
	{
		{
			action = atk1,
			cells =
			{
				CPos.New(15, 41),
				CPos.New(15, 42),
				CPos.New(15, 43),
				CPos.New(15, 44)
			}
		},
		{
			-- TODO Probably remove in favor of proximity.
			action = function()
			end,
			--action = OnConstructionYardDiscovered,
			cells =
			{
				CPos.New(9, 40),
				CPos.New(10, 40),
				CPos.New(11, 40)
			}
		},
		{
			-- TODO remove. Infantry pool production from the start.
			-- Vehicle teams follow after capture or base defense.
			action = function()
			end,
			cells =
			{
				CPos.New(27, 39),
				CPos.New(28, 39),
				CPos.New(29, 39),
				CPos.New(30, 39),
				CPos.New(31, 39),
				CPos.New(32, 39),
				CPos.New(33, 39),
				CPos.New(34, 39),
				CPos.New(35, 39)
			}
		}
	}

	Utils.Do(footprints, function(foot)
		local activated = false

		Trigger.OnEnteredFootprint(foot.cells, function(actor, id)
			if activated or not IsMobileNod(actor) then
				return
			end

			activated = true
			Trigger.RemoveFootprintTrigger(id)
			foot.action()
		end)
	end)
end

local function PrepareAreaGuards()
	local teams =
	{
		{
			actors = { SouthGrenadier1, SouthGrenadier2, SouthGrenadier3, SouthGrenadier4 },
			range = 6
		},
		{
			actors = { SouthBridgeTank },
			range = 8
		},
		{
			actors = { WestEdgeTank }
		},
		{
			actors = { BridgeHumvee }
		}
	}

	Utils.Do(teams, function(team)
		local radius = WDist.FromCells(team.range or 7)
		local center = team.center or team.actors[1].CenterPosition
		GuardArea(team.actors, center, radius)
	end)
end

local function ReinforceNorthNod()
	Media.PlaySpeechNotification(Nod, "Reinforce")

	Trigger.AfterDelay(DateTime.Seconds(5), function()
		PrepareTechObjectives()

		if NodReinforceCamera.IsInWorld then
			NodReinforceCamera.Destroy()
		end
	end)

	local formation =
	{
		{
			types = { "e3", "e3", "e3", "e3" },
			-- Rally is switched with rifles to protect these from the scout.
			path = { NodEntry1.Location, NodRally2.Location }
		},
		{
			types = { "e6", "e6", "e6" },
			path = { NodEntry2.Location, NodRally1.Location },
			delay = DateTime.Seconds(2)
		},
		{
			types = { CommandoTypes[Difficulty] },
			path = { NodEntry2.Location, NodRally3.Location },
			action = function(actor)
				-- "Time to rock 'n' roll!"
				actor.GrantCondition("produced")
			end
		},
		{
			types = { "e1", "e1", "e1", "e1" },
			path = { NodEntry3.Location, NodRally4.Location }
		}
	}

	Utils.Do(formation, function(team)
		Trigger.AfterDelay(team.delay or 0, function()
			Reinforcements.Reinforce(Nod, team.types, team.path, 15, team.action)
		end)
	end)
end

local function MoveStartingCamera()
	if not StartingCameraMovement.Enabled then
		return
	end

	if Camera.Position.Y <= StartingCameraMovement.CutoffY then
		StartingCameraMovement.Enabled = false
		ReinforceNorthNod()
		return
	end

	if Camera.Position ~= StartingCameraMovement.ExpectedPosition then
		StartingCameraMovement.InterruptedTicks = StartingCameraMovement.InterruptedTicks + 1
	end

	-- If the player seems to be trying to break out of the movement, let them.
	if StartingCameraMovement.InterruptedTicks >= StartingCameraMovement.InterruptThreshold then
		StartingCameraMovement.Enabled = false
		ReinforceNorthNod()
		return
	else
		Camera.Position = StartingCameraMovement.ExpectedPosition
	end

	Camera.Position = Camera.Position + StartingCameraMovement.Vector
	StartingCameraMovement.ExpectedPosition = Camera.Position
end

WorldLoaded = function()
	Camera.Position = NodCameraStart.CenterPosition

	PrepareBasicFootprintTriggers()
	PrepareAreaGuards()
	PrepareTowerReveals()
	PrepareConstructionYardDiscovery()

	Trigger.AfterDelay(DateTime.Seconds(1), function()
		StartingCameraMovement.Enabled = true
	end)
end

Tick = function()
	MoveStartingCamera()

	if not TechCenterReclaimed then
		return
	end

	if DestroyGDI and GDI.HasNoRequiredUnits() then
		Nod.MarkCompletedObjective(DestroyGDI)
		return
	end

	if GDI.Resources > GDI.ResourceCapacity * 0.75 then
		GDI.Cash = GDI.Cash + (GDI.Resources * 0.25)
		GDI.Resources = GDI.Resources * 0.75
	end

	if Nod.HasNoRequiredUnits() then
		MarkNodDead()
	end
end
