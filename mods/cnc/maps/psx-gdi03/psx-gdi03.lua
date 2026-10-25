--[[
   Copyright (c) The OpenRA Developers and Contributors
   This file is part of OpenRA, which is free software. It is made
   available to you under the terms of the GNU General Public License
   as published by the Free Software Foundation, either version 3 of
   the License, or (at your option) any later version. For more
   information, see COPYING.
]]

local GDI = Player.GetPlayer("GDI")
local Nod = Player.GetPlayer("Nod")
local Neutral = Player.GetPlayer("Neutral")

local EliminateNod = AddPrimaryObjective(GDI, "eliminate-nod")
local DestroySams = AddSecondaryObjective(GDI, "destroy-sams")

local EngineerAttackStarted = false
local HouseExits =
{
	v20 = CVec.New(0, 1),
	v21 = CVec.New(0, 0),
	v22 = CVec.New(1, 0),
	v24 = CVec.New(0, 1),
	v26 = CVec.New(0, 0)
}

---@param posA wpos
---@param posB wpos
---@return integer
local function SquaredDistance(posA, posB)
	local diffX = posA.X - posB.X
	local diffY = posA.Y - posB.Y
	return diffX * diffX + diffY * diffY
end

---@param origin wpos Point from which distances are measured.
---@param actors actor[] Targets to sort.
---@return actor[]
local function ActorsByDistance(origin, actors)
	local sort = table.sort

	sort(actors, function(a, b)
		return SquaredDistance(origin, a.CenterPosition) < SquaredDistance(origin, b.CenterPosition)
	end)

	return actors
end

---@param origin wpos
---@return actor[]
local function GetEngineerTargets(origin)
	-- This is loosely based on the original priorities from THREAT_BUILDINGS.
	local typesByPriority =
	{
		[1] = { "afld", "eye", "fact", "proc", "proc.outpost", "weap" },
		[2] = { "fix", "hq", "nuk2" },
		[3] = { "hand", "hpad", "nuke", "pyle" }
	}

	for i = 1, #typesByPriority do
		local targets = GDI.GetActorsByTypes(typesByPriority[i])

		if #targets > 0 then
			return ActorsByDistance(origin, targets)
		end
	end

	return { }
end

--- Order Engineers to capture enemy buildings. The CnC mod uses "sabotage"
--- captures, so Engineers should group on the same target.
---@param engineers actor[]
---@param startPosition wpos
local function OrderEngineers(engineers, startPosition)
	local enemyStructures = GetEngineerTargets(startPosition)

	---@type actor|nil
	local target = enemyStructures[1]

	Utils.Do(engineers, function(engineer)
		Trigger.OnIdle(engineer, function()
			if target and not target.IsDead and engineer.CanCapture(target) then
				engineer.Capture(target)
				return
			end

			target = nil

			Utils.Do(enemyStructures, function(structure)
				if target or structure.IsDead or not engineer.CanCapture(structure) then
					return
				end

				target = structure
			end)

			if not target then
				enemyStructures = GetEngineerTargets(startPosition)
				engineer.Wait(100)
			end
		end)
	end)
end

local function SendEngineers()
	if EngineerAttackStarted then
		return
	end
	EngineerAttackStarted = true

	local cargos =
	{
		default = { "e6", "e6", "e6", "e6", "e6" },
		hard = { "e6", "e6", "e6", "e6", "e6", "e6", "e6", "e6", "e6", "e6" }
	}
	local path = { CPos.New(Utils.RandomInteger(2, 61), NorthEntry1.Location.Y), Waypoint23.Location }
	local engineers = Reinforcements.ReinforceWithTransport(Nod, "tran", cargos[Difficulty] or cargos.default, path, { path[1] })[2]
	OrderEngineers(engineers, Waypoint23.CenterPosition)
end

local function ReinforceStartingUnits()
	local reinforcements =
	{
		medium1 =
		{
			type = "mtnk",
			path = { NorthEntry3.Location, StartTankRally1.Location },
			announced = true
		},
		medium2 =
		{
			type = "mtnk",
			path = { NorthEntry2.Location, StartTankRally2.Location },
			facing = Angle.South
		},
		mammoth =
		{
			type = "htnk",
			path = { NorthEntry1.Location, Waypoint22.Location },
			delay = DateTime.Seconds(2)
		},
		builder =
		{
			type = "mcv",
			path = { NorthEntry1.Location, BuilderRally.Location },
			announced = true,
			delay = DateTime.Seconds(21)
		},
		easy1 =
		{
			type = "jeep",
			path = { NorthEntry3.Location, EasySupportRally1.Location },
			condition = "easy" == Difficulty,
			delay = DateTime.Seconds(4),
			facing = Angle.South
		},
		easy2 =
		{
			type = "jeep",
			path = { NorthEntry1.Location, EasySupportRally2.Location },
			condition = "easy" == Difficulty,
			delay = DateTime.Seconds(4),
			facing = Angle.South
		},
		easy3 =
		{
			type = "rmbo.easy",
			path = { NorthEntry1.Location, EasySupportRally3.Location },
			condition = "easy" == Difficulty,
			delay = DateTime.Seconds(6)
		}
	}

	Utils.Do(reinforcements, function(r)
		Trigger.AfterDelay(r.delay or 0, function()
			if r.announced then
				Media.PlaySpeechNotification(GDI, "Reinforce")
			end

			if r.condition == false or not r.type or not r.path then
				return
			end

			local unit = Actor.Create(r.type, true, { Owner = GDI, Location = r.path[1], Facing = r.facing or Angle.SouthEast })
			Utils.Do(r.path, unit.Move)

			if unit.HasProperty("Demolish") then
				-- "Time to rock and roll!"
				unit.GrantCondition("produced")
			end
		end)
	end)
end

local function PrepareWestBaseCrate()
	local buildCosts =
	{
		Actor.Cost("nuke") + Actor.Cost("pyle") + Actor.Cost("e6"),
		Actor.Cost("nuke") + Actor.Cost("proc")
	}

	-- In the original mission, this crate did not give enough money to build a
	-- refinery, but it did allow capturing Nod's refinery (and harvester).
	-- We likewise restrict the cash, if it makes sense with current ORA costs.
	local crateCash = math.min(buildCosts[1], buildCosts[2])
	local blocker = Actor.Create("crateblocker", true, { Owner = Nod, Location = WestBaseCrate.Location })

	Trigger.OnRemovedFromWorld(WestBaseCrate, function(crate)
		GDI.Cash = GDI.Cash + crateCash
		Media.FloatingText("+$" .. tostring(crateCash), crate.CenterPosition, 30, GDI.Color)

		if blocker.IsInWorld then
			blocker.Destroy()
		end
	end)
end

---@param actors actor[]
local function PrepareWestGuards(actors)
	local hunting = false

	Utils.Do(actors, function(a)
		a.AddTag("West Infantry")

		Trigger.OnDamaged(a, function(_, attacker)
			-- Owner check is partly to ignore Tiberium damage from Neutral.
			if hunting or attacker.Owner ~= GDI or attacker.IsDead or not attacker.IsInWorld then
				return
			end
			hunting = true

			-- Edge case: player actor could damage us with the Ion Cannon.
			if attacker.Type == "player" then
				Utils.Do(Map.ActorsWithTag("West Infantry"), IdleHunt)
			else
				MoveAndHunt(Map.ActorsWithTag("West Infantry"), { attacker })
			end
		end)
	end)
end

local function OnCrateTurretKilled()
	Utils.Do(Map.ActorsWithTag("West Infantry"), function(a)
		a.AttackMove(Waypoint24.Location, 2)
	end)

	if Difficulty ~= "hard" or WestHand.IsDead or WestHand.Owner ~= Nod then
		return
	end

	WestHand.Build({ "e1", "e3", "e1", "e3", "e4" }, PrepareWestGuards)
end

---@param house actor
---@param types string[]
---@param facings wangle[]
---@param goalCells cpos[]
local function EvacuateHouse(house, types, facings, goalCells)
	local spawnOffset = HouseExits[house.Type]
	local civCount = Utils.RandomInteger(0, 3)
	if civCount == 0 or not spawnOffset then
		return
	end

	for i = 1, civCount do
		local civ = Actor.Create(types[i] or Utils.Random(types), true, { Owner = Neutral, Location = house.Location + spawnOffset, Facing = Utils.Random(facings), SubCell = 2 })
		local goal = Utils.Random(goalCells)
		civ.Scatter()

		Trigger.OnIdle(civ, function()
			if civ.Location == goal then
				civ.Destroy()
				return
			end

			civ.Move(goal)
		end)
	end
end

local function PrepareVillagers()
	-- Minus the church with a crate, and the well.
	local houses = Neutral.GetActorsByTypes({ "v20", "v21", "v22", "v24", "v26" })
	local villagerTypes = { "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c9" }
	local goalCells = { VillagerExitNorth.Location, VillagerExitEast.Location }
	local facings = { Angle.SouthWest, Angle.South, Angle.SouthEast }

	Utils.Do(houses, function(house)
		Trigger.OnKilled(house, function()
			EvacuateHouse(house, Utils.Shuffle(villagerTypes), facings, goalCells)
		end)
	end)
end

WorldLoaded = function()
	InitObjectives(GDI)
	Camera.Position = Waypoint22.CenterPosition
	Nod.Resources = Nod.ResourceCapacity * 0.6
	SouthHand.RallyPoint = SouthHand.Location + CVec.New(1, 2)

	PrepareWestBaseCrate()
	PrepareWestGuards(Map.ActorsWithTag("West Infantry"))
	PrepareVillagers()
	ReinforceStartingUnits()
	ActivateAI()

	-- Teams "nod1" and "nod2".
	for i = 1, 2 do
		local point = Map.NamedActor("Waypoint" .. i)
		local rotorOffset = i * 2

		-- Start airborne and then land to ensure correctly occupied cells.
		local transport = Actor.Create("tran.capturable", true, { Owner = Nod, CenterPosition = point.CenterPosition + WVec.New(0, 0, Actor.CruiseAltitude("tran.capturable")) })
		transport.Wait(rotorOffset)
		transport.Land(point)
	end

	-- Trigger "flre".
	Trigger.OnAllKilledOrCaptured({ VillageSam1, VillageSam2 }, function()
		Actor.Create("flare", true, { Owner = GDI, Location = FlareEntry.Location })
	end)

	-- Trigger "a10", though with the village SAMs now included.
	Trigger.OnAllKilledOrCaptured(Nod.GetActorsByType("sam"), function()
		Actor.Create("airstrike.proxy", true, { Owner = GDI })
		GDI.MarkCompletedObjective(DestroySams)
	end)

	-- Trigger "hunt".
	Trigger.OnAllKilledOrCaptured({ SouthHand, SouthPower1, SouthPower2, Airstrip, ConstructionYard }, function()
		Utils.Do(Nod.GetGroundAttackers(), IdleHunt)
	end)

	-- Trigger "engr". Demolish and Engineer sabotages will also trigger this.
	Trigger.OnDamaged(SouthPower4, SendEngineers)

	Utils.Do({ NorthEastStealthTank, EastEdgeFlameTank }, function(tank)
		Trigger.OnDamaged(tank, function(_, attacker)
			-- Keep near this ambush spot unless we're clearly under attack.
			if tank.IsDead or tank.Stance == "AttackAnything" or tank.Health > tank.MaxHealth * 0.9 or attacker.IsDead or not attacker.IsInWorld then
				return
			end

			if attacker.Type ~= "player" then
				tank.AttackMove(attacker.Location, 2)
			end

			tank.Stance = "AttackAnything"
			IdleHunt(tank)
		end)
	end)

	local turretDefendersCalled = false

	-- Trigger "nod8".
	Utils.Do({ WestTurret1, WestTurret2 }, function(turret)
		Trigger.OnKilledOrCaptured(turret, function()
			if turretDefendersCalled then
				return
			end

			turretDefendersCalled = true
			OnCrateTurretKilled()
		end)
	end)

	Utils.Do({ WestHand, WestPower1, WestPower2, WestRefinery }, function(building)
		Trigger.OnDamaged(building, function()
			if WestTank.IsDead or not WestTank.IsIdle then
				return
			end

			WestTank.Hunt()
		end)
	end)

	-- Starting infantry are likely dead. This is more for Hard's second wave.
	Trigger.OnKilled(WestTank, function()
		Utils.Do(Map.ActorsWithTag("West Infantry"), IdleHunt)
	end)
end

Tick = function()
	if Nod.Resources > Nod.ResourceCapacity * 0.9 then
		Nod.Cash = Nod.Cash + Nod.ResourceCapacity * 0.1
		Nod.Resources = Nod.ResourceCapacity * 0.8
	end

	if Nod.HasNoRequiredUnits() then
		GDI.MarkCompletedObjective(EliminateNod)
		return
	end

	if GDI.HasNoRequiredUnits() then
		GDI.MarkFailedObjective(EliminateNod)
	end
end
