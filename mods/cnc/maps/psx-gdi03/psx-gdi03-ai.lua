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

--- Actor types to be built by the south base, with optional infantry recruited
--- as the build finishes. These will mostly be AutoTeams or lone harvesters.
---@type { types: string[], infantryRequests?: number[], onBuilt?: fun(actors: actor[]) }[]
local QueuedTeams = { }

---@type { types: string[], onBuilt?: fun(actors: actor[]) }
local QueuedInfantryBuilds = { }

--- Have Nod units been recently called to an attacked building/harvester?
local BaseDefendersAlerted = false
local HardBarracksCreated = false
local MainProductionActivated = false
local AutoTeamsActivated = false
local AutoTeamIntervals =
{
	easy = DateTime.Seconds(90),
	default = DateTime.Seconds(60),
	hard = DateTime.Seconds(25)
}

--- Ticks until the main base begins attacker production.
local SouthBaseDelays =
{
	default = DateTime.Seconds(450),
	hard = DateTime.Seconds(300)
}

--- Teams built at random once the main Nod base is activated.
---@type { types: string[]?, infantryRequests?: number[], onBuilt?: fun(actors: actor[]), route?: actor[], condition?: boolean }
local AutoTeams =
{
	nod7 =
	{
		types = { "bggy", "bike", "bike" },
	},
	nod8 =
	{
		types = { "ftnk", "bike" },
	},
	nod9 =
	{
		types = { "ltnk", "arty", "arty" },
	},
	nod10 =
	{
		types = { "stnk", "stnk" },
		route = { Waypoint8, Waypoint9, Waypoint10, Waypoint11, Waypoint12, Waypoint13 }
	},
	nod11 =
	{
		types = { "stnk" },
		route = { Waypoint4, Waypoint3, Waypoint14, Waypoint15 }
	},
	nod12 =
	{
		types = { "ltnk" },
		infantryRequests = { ["e1"] = 2 }
	},
	nod13 =
	{
		types = { "e3", "e3", "e4", "e4", "e4" },
		onBuilt = function(actors)
			MoveAndHunt(actors, { Waypoint4, Waypoint3, Waypoint14, Waypoint15 })
		end
	},
	hard1 =
	{
		types = { "ltnk", "ltnk", "arty", "arty" },
		infantryRequests = { ["e3"] = 2, ["e1"] = 2 },
		condition = "hard" == Difficulty
	},
	hard2 =
	{
		types = { "ftnk", "bike", "bike" },
		infantryRequests = { ["e3"] = 2, ["e4"] = 2 },
		condition = "hard" == Difficulty
	},
	hard3 =
	{
		types = { "ltnk", "ltnk", "ftnk" },
		infantryRequests = { ["e3"] = 2, ["e4"] = 1, ["e1"] = 2 },
		condition = "hard" == Difficulty
	}
}

--- Types produced from buildings that Nod has been lucky enough to capture.
local CapturedProducerTypes =
{
	afld = { "ftnk", "ltnk" },
	hand = { "e1", "e4" },
	hpad = { "orca" },
	pyle = { "e1", "e2" },
	weap = { "mtnk" }
}

---@type actor[][]
local MainAttackRoutes =
{
	south = { Waypoint4, Waypoint3, Waypoint14, Waypoint15 },
	middle = { Waypoint4, Waypoint6, Waypoint7, RoadCenter },
	edge = { Waypoint8, Waypoint9, Waypoint10, Waypoint11, Waypoint12, Waypoint13 }
}

---@return table
local function NextAutoTeam()
	return Utils.Random(Utils.Where(AutoTeams, function(team)
		return team.condition == nil or team.condition == true
	end))
end

---@param infantryIncluded boolean
---@return actor[]
local function RandomAutoRoute(infantryIncluded)
	if infantryIncluded then
		-- Some teams should skip the north route that is choked with tiberium.
		return Utils.Random({ MainAttackRoutes.south, MainAttackRoutes.middle })
	end

	return Utils.Random(MainAttackRoutes)
end

---@param actor actor
---@param target actor
---@param cellDistance integer
---@return boolean
local function IsNearTarget(actor, target, cellDistance)
	return 1 == #Map.ActorsInCircle(actor.CenterPosition, WDist.FromCells(cellDistance), function(aic)
		return target == aic
	end)
end

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
local function ActorsByDescendingDistance(origin, actors)
	local sort = table.sort

	sort(actors, function(a, b)
		-- Unlike the bot's Engineers, these units should try to
		-- attack targets farthest from the presumed front line.
		return SquaredDistance(origin, a.CenterPosition) > SquaredDistance(origin, b.CenterPosition)
	end)

	return actors
end

--- Order Nod units to harass backline GDI structures.
--- This is a loose match for the original ATTACK_BASE orders.
---@param actors actor[] Bot actors ordered to harass.
---@param structureTypes string[] Enemy types to target.
---@param origin wpos Point from which target distances are measured.
local function HarassStructures(actors, structureTypes, origin)
	local structures = ActorsByDescendingDistance(origin, GDI.GetActorsByTypes(structureTypes))
	if #structures == 0 then
		Utils.Do(actors, IdleHunt)
		return
	end

	local target = structures[1]
	local targetId = 1
	local hunting = false

	Utils.Do(actors, function(a)
		-- We'll attempt to ignore and move past any defenders for this attack.
		a.Stance = "HoldFire"

		Trigger.OnIdle(a, function()
			if hunting then
				a.Stance = "AttackAnything"
				a.Hunt()
				return
			end

			if not target or target.IsDead or not a.CanTarget(target) then
				targetId = targetId + 1
				target = structures[targetId]
				hunting = targetId > #structures
				return
			end

			-- Bibs often leave this cell open, even in a cluttered base.
			a.Move(target.Location + CVec.New(0, -1), 2)

			a.CallFunc(function()
				if not target or target.IsDead or not a.CanTarget(target) then
					return
				end

				a.Attack(target, true, true)
			end)
		end)
	end)
end

---@param actors actor[]
---@param point actor
---@param cellDistance integer
---@return boolean
local function IsTeamAtPoint(actors, point, cellDistance)
	return Utils.All(actors, function(a)
		-- Don't wait on dead members who will never arrive.
		return a.IsDead or a.Location == point.Location or IsNearTarget(a, point, cellDistance)
	end)
end

--- Order newly built units to move through a path, waiting at
--- each point for team members to gather before continuing.
---@param units actor[]
---@param points actor[]
---@param looped? boolean
local function AttackAsTeam(units, points, looped)
	local unitCount = #units
	if unitCount == 0 then
		return
	end

	local rushing = false
	local hunting = false
	local arrived = { }
	local goal = 1

	for id = 1, unitCount do
		Trigger.OnDamaged(units[id], function(unit, damager)
			if rushing then
				return
			end

			rushing = unit.IsDead or damager.Owner == GDI and not damager.IsDead and unit.Health < unit.MaxHealth * 0.9
		end)

		Trigger.OnIdle(units[id], function(unit)
			if hunting then
				unit.Hunt()
				return
			end

			-- Move to the point, or try to remain idle if we already reached
			-- it. Idling allows later arrivals to nudge us as needed.
			arrived[id] = arrived[id] or unit.Location == points[goal].Location or IsNearTarget(unit, points[goal], 2)
			if not arrived[id] then
				unit.AttackMove(points[goal].Location)
				return
			end

			if not rushing and not IsTeamAtPoint(units, points[goal], 3) then
				return
			end

			arrived = { }
			goal = goal + 1

			if goal <= #points then
				return
			end

			if looped then
				goal = 1
				return
			end

			hunting = true
		end)
	end
end

---@param actor actor
local function DefendActor(actor)
	if actor.IsDead then
		return
	end

	Trigger.OnDamaged(actor, function(_, attacker)
		if BaseDefendersAlerted or actor.Owner ~= GDI or attacker.IsDead or actor.IsDead or attacker.Type == "player" then
			return
		end
		BaseDefendersAlerted = true

		Utils.Do(Map.ActorsWithTag("Base Defender"), function(defender)
			defender.RemoveTag("Recruitable Infantry")
			defender.AttackMove(attacker.Location, 2)
			IdleHunt(defender)
		end)

		Trigger.AfterDelay(DateTime.Seconds(15), function()
			BaseDefendersAlerted = false
		end)
	end)
end

--- Attempt to build infantry at the west base whenever the main base does.
---@param types string[]
local function BuildWestInfantry(types)
	if not MainProductionActivated or WestHand.IsDead or WestHand.Owner ~= Nod or WestHand.IsProducing("e1") then
		return
	end

	WestHand.Build(types, function(actors)
		Utils.Do(actors, IdleHunt)
	end)
end

local function CreateHardBarracks()
	if HardBarracksCreated or Difficulty ~= "hard" then
		return
	end

	HardBarracksCreated = true
	local hand = Actor.Create("hand", true, { Owner = Nod, Location = HardHandEntry.Location })

	local toBuild = function()
		local infantry = { }

		for i = 1, Utils.RandomInteger(5, 8) do
			infantry[i] = Utils.Random({ "e1", "e1", "e1", "e3", "e4" })
		end

		return infantry
	end

	local toDelay = function()
		return AutoTeamIntervals.hard or AutoTeamIntervals.default
	end

	Trigger.AfterDelay(DateTime.Seconds(60), function()
		if hand.IsDead or hand.Owner ~= Nod then
			return
		end

		ProduceUnits(Nod, hand, toDelay, toBuild, function(actors)
			AttackAsTeam(actors, RandomAutoRoute(true))
		end)
	end)
end

--- Build infantry at the main base. This is mostly for (re)building an initial
--- batch that is recruited for assignments, rather than purpose-built teams.
---@param types string[]
---@param fromQueue? boolean
---@param onBuilt? fun(actors: actor[])
local function BuildInfantry(types, onBuilt, fromQueue)
	if SouthHand.IsDead or SouthHand.Owner ~= Nod or SouthHand.IsProducing("e1") then
		if not fromQueue then
			QueuedInfantryBuilds[#QueuedInfantryBuilds + 1] = { types = types, onBuilt = onBuilt }
		end

		return
	end

	SouthHand.Build(types, function(actors)
		BuildWestInfantry(types)

		if onBuilt then
			onBuilt(actors)
		else
			Utils.Do(actors, function(a)
				a.AddTag("Base Defender")
				a.AddTag("Recruitable Infantry")

				Trigger.OnKilled(a, function()
					BuildInfantry({ a.Type })
				end)
			end)
		end

		if fromQueue then
			table.remove(QueuedInfantryBuilds, 1)
		end

		if QueuedInfantryBuilds[1] then
			BuildInfantry(QueuedInfantryBuilds[1].types, QueuedInfantryBuilds[1].action, true)
		end
	end)
end

---@param requests number[]
local function RecruitInfantry(requests)
	local pool = Map.ActorsWithTag("Recruitable Infantry")
	local infantry = { }

	for type, count in pairs(requests) do
		local matchingTypes = Utils.Where(pool, function(a)
			return a.Type == type
		end)

		infantry = Utils.Concat(infantry, Utils.Take(count, matchingTypes))
	end

	Utils.Do(infantry, function(a)
		a.RemoveTag("Recruitable Infantry")
	end)

	return infantry
end

--- Build and send some units on a task, with optional infantry. Rather than
--- building them for the task, most infantry are recruited from a reserve.
---@param types string[]
---@param infantryRequests? number[]
---@param onBuilt? fun(actors: actor[])
---@param fromQueue? boolean
local function BuildTeam(types, infantryRequests, onBuilt, fromQueue)
	-- Special case for "nod13", a group with no vehicles.
	if types[1] == "e3" then
		BuildInfantry(types, onBuilt)

		if fromQueue then
			-- Unlike most teams, we remove this from the queue now instead
			-- of post-build. The team is now BuildInfantry's responsibility.
			table.remove(QueuedTeams, 1)
		end

		-- Start on the next team in our queue, if any.
		if QueuedTeams[1] then
			BuildTeam(QueuedTeams[1].types, QueuedTeams[1].infantryRequests, QueuedTeams[1].onBuilt, true)
			return
		end

		Trigger.AfterDelay(AutoTeamIntervals[Difficulty] or AutoTeamIntervals.default, function()
			local team = NextAutoTeam()
			BuildTeam(team.types, team.infantryRequests, team.onBuilt)
		end)

		return
	end

	if Airstrip.IsDead or Airstrip.Owner ~= Nod or Airstrip.IsProducing("bggy") then
		if not fromQueue then
			-- Unbuildable for now and not requested from the queue? Queue it.
			QueuedTeams[#QueuedTeams + 1] = { types = types, infantryRequests = infantryRequests, onBuilt = onBuilt }
		end

		return
	end

	Airstrip.Build(types, function(actors)
		if infantryRequests then
			actors = Utils.Concat(actors, RecruitInfantry(infantryRequests))
		end

		if onBuilt then
			onBuilt(actors)
		else
			-- We don't have a special task, so do a standard attack.
			AttackAsTeam(actors, RandomAutoRoute(infantryRequests ~= nil))
		end

		if fromQueue then
			table.remove(QueuedTeams, 1)
		end

		if QueuedTeams[1] then
			BuildTeam(QueuedTeams[1].types, QueuedTeams[1].infantryRequests, QueuedTeams[1].onBuilt, true)
			return
		end

		if not AutoTeamsActivated then
			return
		end

		Trigger.AfterDelay(AutoTeamIntervals[Difficulty] or AutoTeamIntervals.default, function()
			local team = NextAutoTeam()
			BuildTeam(team.types, team.infantryRequests, team.onBuilt)
		end)
	end)
end

---@param harvester actor
local function PrepareNewHarvester(harvester)
	Trigger.OnKilledOrCaptured(harvester, function()
		table.insert(QueuedTeams, 1, { types = { "harv" }, onBuilt = function(actors) PrepareNewHarvester(actors[1]) end })
	end)

	DefendActor(harvester)
end

--- Produce random hunters at producers freshly captured by Nod.
---@param producer actor
local function OnPlayerProducerCaptured(producer)
	local typesToBuild = CapturedProducerTypes[producer.Type]
	if not typesToBuild then
		return
	end

	local toDelay = function() return 125 end
	local toBuild = function() return Utils.Random(typesToBuild) end

	ProduceUnits(Nod, producer, toDelay(), toBuild(), function(actors)
		Utils.Do(actors, IdleHunt)
	end)
end

local function OnSouthBaseActivated()
	if MainProductionActivated then
		return
	end

	MainProductionActivated = true
	AutoTeamsActivated = true
	Nod.GrantCondition("nod-builder-enabled")

	--[[
		Team "nod5". This was an odd case in the original map where a footprint
		created the team in the first moments. However, bikes were not actually
		built and assigned until much later when Nod production started.
	]]
	BuildTeam({ "bike", "bike", "bike" }, nil, function(bikes)
		MoveAndIdle(bikes, MainAttackRoutes.middle)
		HarassStructures(bikes, { "afld", "eye", "fact", "hq", "proc", "proc.outpost", "weap" }, RoadCenter.CenterPosition)
	end)
end

local function PrepareSouthBaseWake()
	local activated = false
	local southBase = Utils.Where(Nod.GetActors(), function(a)
		return a.Type ~= "player" and a.Location.Y > Waypoint4.Location.Y and (a.HasProperty("StartBuildingRepairs") or a.HasProperty("FindResources"))
	end)

	Utils.Do(southBase, function(actor)
		Trigger.OnDamaged(actor, function(_, attacker)
			-- HP check is meant to ignore light autotarget damage from scouts.
			if activated or attacker.Owner ~= GDI or actor.IsDead or actor.Health > actor.MaxHealth * 0.9 then
				return
			end

			activated = true
			OnSouthBaseActivated()
			CreateHardBarracks()
		end)

		if not actor.HasProperty("Attack") then
			DefendActor(actor)
		end
	end)

	Trigger.AfterDelay(SouthBaseDelays[Difficulty] or SouthBaseDelays.default, OnSouthBaseActivated)
end

local function PrepareEarlyTeams()
	local patrolRequested = false

	-- This is based on original trigger/team "nod3". These soldiers act as
	-- base defenders, or as infantry support for some vehicle teams.
	-- Delayed because producers will not be ready on their first living tick.
	Trigger.AfterDelay(1, function()
		BuildInfantry({ "e1", "e1", "e3", "e3", "e4", "e4", "e4" }, nil, false)
	end)

	-- Trigger "nod4", team "nod4".
	Trigger.AfterDelay(DateTime.Seconds(300), function()
		BuildTeam({ "ltnk" }, { ["e4"] = 2 }, function(actors)
			AttackAsTeam(actors, { Waypoint4, Waypoint3, Waypoint14, Waypoint15 })
		end)
	end)

	-- Trigger "nod6", team "nod4".
	Trigger.AfterDelay(DateTime.Seconds(450), function()
		BuildTeam({ "ltnk" }, { ["e4"] = 2 }, function(actors)
			AttackAsTeam(actors, { Waypoint4, Waypoint3, Waypoint14, Waypoint15 })
		end)
	end)

	-- Trigger "nod7", team "nod6".
	Trigger.AfterDelay(DateTime.Seconds(480), function()
		BuildInfantry({ "e1", "e1", "e3", "e3", "e4", "e4" }, function(actors)
			AttackAsTeam(actors, { Waypoint4, Waypoint6, Waypoint7 })
		end)
	end)

	-- Trigger "nod9", though the patrol does not pause as long at each point.
	Utils.Do({ WestTurret3, WestTurret4, NorthEastStealthTank }, function(turret)
		Trigger.OnDamaged(turret, function()
			if patrolRequested then
				return
			end
			patrolRequested = true

			BuildTeam({ "bggy", "bike" }, nil, function(actors)
				AttackAsTeam(actors, { Waypoint8, Waypoint9, Waypoint7, Waypoint6, Waypoint4 }, true)
			end)
		end)
	end)
end

ActivateAI = function()
	RepairNamedActors(Nod, 0.75)
	PrepareSouthBaseWake()
	PrepareEarlyTeams()
	Utils.Do({ SouthHarvester1, SouthHarvester2 }, PrepareNewHarvester)

	Trigger.OnBuildingPlaced(Nod, function(_, building)
		RepairBuilding(Nod, building, 0.75)

		if not building.HasProperty("Attack") then
			DefendActor(building)
		end

		if building.Type == "afld" then
			local team = NextAutoTeam()
			Airstrip = building

			Trigger.AfterDelay(1, function()
				BuildTeam(team.types, team.infantryRequests, team.onBuilt)
			end)
		elseif building.Type == "hand" then
			SouthHand = building

			Trigger.AfterDelay(1, function()
				BuildInfantry({ "e1" }, IdleHunt)
			end)
		end
	end)

	Trigger.OnBuildingPlaced(GDI, function(_, building)
		if building.Type == "nuke" then
			CreateHardBarracks()
		end

		if not CapturedProducerTypes[building.Type] then
			return
		end

		Trigger.OnCapture(building, function(_, captor)
			if captor.Owner ~= Nod then
				return
			end

			OnPlayerProducerCaptured(building)
		end)
	end)

	AutoTeams.nod10.onBuilt = function(actors)
		MoveAndIdle(actors, AutoTeams.nod10.route)
		HarassStructures(actors, { "afld", "eye", "fact", "hq", "proc", "proc.outpost", "weap" }, Waypoint13.CenterPosition)
	end

	AutoTeams.nod11.onBuilt = function(actors)
		MoveAndIdle(actors, AutoTeams.nod11.route)
		HarassStructures(actors, { "afld", "eye", "fact", "hq", "proc", "proc.outpost", "weap" }, Waypoint15.CenterPosition)
	end
end
