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

---@type number? Delayed objective to destroy the main base.
local DestroyNorthBase
local EstablishBeach = AddPrimaryObjective(GDI, "establish-beachhead")
--- This objective is mostly added to encourage destruction of the
--- eastern base buildings, which can trigger more GDI reinforcements.
local EliminateNod = AddSecondaryObjective(GDI, "eliminate-nod")

--- Is an LST busy delivering vehicles?
local BeachReserved = false
--- Are Nod's defenses by the beach all destroyed?
local BeachEstablished = false
--- Should the next Easy difficulty LST be doubled?
local NextBeachTeamDoubled = false
--- Has a player moved past the north gate or destroyed a building inside?
local NorthBaseEntered = false
--- Has the player approached the eastern Nod base, triggering its flare?
local FlareActivated = false
local CommandoArrived = false
local ChurchDiscovered = false
local BeachGrenadiersCalled = false
local DefeatStarted = false
local VictoryStarted = false

local BeachTeamPaths =
{
	Center = { BeachEntryCenter.Location, BeachUnloadCenter.Location, BeachRallyCenter.Location },
	Left = { BeachEntryLeft.Location, BeachUnloadLeft.Location, BeachRallyLeft.Location },
	Right = { BeachEntryRight.Location, BeachUnloadRight.Location, BeachRallyRight.Location }
}

--- Groups that the bot should build with idle Nod producers.
local NodQueues =
{
	infantry = { },
	vehicles = { }
}

---@param actor actor
---@return boolean
local function IsDeadOrIdle(actor)
	return actor.IsDead or actor.IsIdle
end

---@param actor actor
---@return boolean
local function IsMobileGDI(actor)
	return actor.Owner == GDI and actor.HasProperty("Move") and actor.Type ~= "boat" and actor.Type ~= "tran.insertion"
end

---@param actor actor
local function TagAsDefender(actor)
	if actor.IsTaggable then
		actor.AddTag("Base Defender")
	end
end

---@param turretsIncluded boolean
---@return actor[]
local function GetNorthBase(turretsIncluded)
	local types = { "afld", "fact", "hand", "hq", "nuke" }
	if turretsIncluded then
		types = { "afld", "fact", "hand", "hq", "nuke", "gun" }
	end

	return Utils.Where(Nod.GetActorsByTypes(types), function(b)
		return b.Location.Y < Waypoint6.Location.Y
	end)
end

---@param baseActors actor[]
---@param cooldown integer
local function DefendBase(baseActors, cooldown)
	local alerted = false

	Utils.Do(baseActors, function(building)
		Trigger.OnDamaged(building, function(_, attacker)
			if alerted or attacker.IsDead or attacker.Owner == building.Owner or attacker.Type == "player" then
				return
			end

			local idleDefenders = Utils.Where(Map.ActorsWithTag("Base Defender"), function(d)
				return d.IsIdle
			end)

			MoveAndHunt(idleDefenders, { attacker })
			alerted = true

			Trigger.AfterDelay(cooldown, function()
				alerted = false
			end)
		end)
	end)
end

--- Order a group to intercept (or chase away) nearby intruders when idle.
--- This is intended to feel similar to GUARD_AREA orders in TD '95.
---@param guards actor[] List of guards.
---@param center wpos Center of the group's search area.
---@param range wdist Radius of the area to guard.
---@param avenged? boolean Should the group IdleHunt if a member has been killed?
local function GuardArea(guards, center, range, avenged)
	local activated = false
	local refreshed = false
	guards = Utils.Where(guards, function(g)
		return not g.IsDead and g.HasTag("Area Guard")
	end)

	if #guards == 0 then
		return
	end

	Trigger.OnEnteredProximityTrigger(center, range, function(target, id)
		if activated or not IsMobileGDI(target) then
			return
		end

		activated = true
		Trigger.RemoveProximityTrigger(id)

		Utils.Do(guards, function(guard)
			if guard.IsDead or not guard.IsIdle or not guard.HasTag("Area Guard") then
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
			local survivors = Utils.Where(guards, function(g)
				return not g.IsDead and guard.HasTag("Area Guard")
			end)

			Utils.Do(survivors, function(survivor)
				Trigger.Clear(survivor, "OnIdle")
			end)

			Trigger.AfterDelay(10, function()
				GuardArea(survivors, center, range, false)
			end)
		end)
	end)

	if not avenged then
		return
	end

	Trigger.OnAnyKilled(guards, function()
		Utils.Do(guards, function(g)
			if g.IsDead then
				return
			end

			g.RemoveTag("Area Guard")
			g.Stance = "AttackAnything"
			IdleHunt(g)
		end)
	end)
end

--- Order a unit to focus key targets until finished or harmed.
---@param unit actor
---@param targets actor[]
local function IdleFocusTargets(unit, targets)
	if unit.IsDead then
		return
	end

	unit.Stance = "ReturnFire"
	local attacked = false
	local done = false
	local i = 1

	Trigger.OnIdle(unit, function()
		if attacked then
			unit.Stance = "AttackAnything"
			unit.Hunt()
			return
		end

		if done then
			return
		end

		if not targets[i].IsDead then
			unit.Attack(targets[i], true, true)
			return
		end

		i = i + 1

		if targets[i] == nil then
			done = true
			unit.Stance = "AttackAnything"
			TagAsDefender(unit)
		end
	end)

	Trigger.OnDamaged(unit, function()
		if attacked or unit.IsDead then
			return
		end

		attacked = true
		Trigger.Clear(unit, "OnDamaged")
		unit.Stop()
	end)
end

---@param types? string[]
local function BuildVehicles(types)
	if types then
		NodQueues.vehicles[#NodQueues.vehicles + 1] = types
	end

	if Airstrip.IsDead or Airstrip.IsProducing("bggy") then
		return
	end

	local desperate = Difficulty == "hard" and NorthBaseEntered and NodQueues.vehicles[1] == nil
	if desperate then
		NodQueues.vehicles[1] = { "ltnk" }
	end

	if not NodQueues.vehicles[1] then
		return
	end

	Airstrip.Build(NodQueues.vehicles[1], function(actors)
		Utils.Do(actors, TagAsDefender)
		table.remove(NodQueues.vehicles, 1)
		BuildVehicles()
	end)
end

---@param types? string[]
local function BuildInfantry(types)
	if types then
		NodQueues.infantry[#NodQueues.infantry + 1] = types
	end

	local producing = Utils.Any({ NorthHand, EastHand }, function(hand)
		return not hand.IsDead and hand.IsProducing("e1")
	end)

	if producing or not Nod.HasPrerequisites({ "hand" }) then
		return
	end

	-- Special case based on original team "pre", which rebuilt once destroyed.
	local desperate = NorthBaseEntered and NodQueues.infantry[1] == nil
	if desperate then
		NodQueues.infantry[1] = { "e1", "e3", "e1", "e3" }
	end

	if not NodQueues.infantry[1] then
		return
	end

	local bothFinished = false

	Utils.Do({ NorthHand, EastHand }, function(hand)
		if hand.IsDead then
			return
		end

		hand.Build(NodQueues.infantry[1], function(actors)
			Utils.Do(actors, TagAsDefender)

			bothFinished = Utils.All({ NorthHand, EastHand }, function(h)
				return h.IsDead or not hand.IsProducing("e1")
			end)

			if bothFinished then
				table.remove(NodQueues.infantry, 1)
				BuildInfantry()
			end
		end)
	end)
end

--- Spawn civilians at the church and evacuate them at the west edge. This does
--- not follow a map trigger, but TD '95 often spawned people from destroyed
--- houses. The nearby Flame Tank would normally torch those civilians.
local function OnChurchDiscovered()
	local types = { "c2", "c4", "c6", "c8" }

	Utils.Do(types, function(type)
		local civ = Actor.Create(type, true, { Owner = Neutral, Location = VillagerEntry.Location, Facing = Angle.SouthWest, SubCell = 2 })
		civ.Scatter()

		-- OnIdle ensures they'll remember their goal after panic.
		Trigger.OnIdle(civ, function()
			if civ.Location == VillagerExit.Location then
				civ.Destroy()
				return
			end

			civ.Move(VillagerExit.Location)
		end)
	end)
end

local function OnEastBaseApproached()
	if FlareActivated then
		return
	end

	FlareActivated = true
	Actor.Create("flare", true, { Owner = GDI, Location = FlareEntry.Location })

	if Difficulty == "hard" and not EastHand.IsDead then
		EastHand.Build({ "e1", "e3", "e1", "e3", "e4" }, function(actors)
			Utils.Do(actors, TagAsDefender)
		end)
	end
end

local function OnNorthNodBaseEntered()
	if NorthBaseEntered then
		return
	end
	NorthBaseEntered = true

	local types =
	{
		infantry =
		{
			default = { "e1", "e1" },
			hard = { "e4", "e3", "e3", "e4" }
		},
		vehicles =
		{
			default = { "ltnk" },
			easy = { "bggy" }
		}
	}

	BuildInfantry(types.infantry[Difficulty] or types.infantry.default)
	BuildVehicles(types.vehicles[Difficulty] or types.vehicles.default)
end

local function OnEastEdgeEntered()
	-- Original team "pre".
	BuildInfantry({ "e1", "e3", "e1", "e3" })

	if not OasisTank.IsDead then
		TagAsDefender(OasisTank)
	end

	if Difficulty == "hard" then
		Nod.GrantCondition("rebuild-enabled")
	end
end

--- This stands in for the original "nod3" approach.
local function OnVillageApproached()
	-- '95 behavior was to Area Guard with units, who would then attack "enemy"
	-- houses. This sometimes led the Flame Tank to wander toward the beach.
	local flamerTargets = { VillageHouse4, VillageWell, VillageHouse3, VillageOil, VillageHouse1, VillageChurch, VillageHouse2 }
	IdleFocusTargets(VillageFlamer, flamerTargets)
	VillageFlamer.Move(VillageHouse4.Location + CVec.New(-1, 0))

	local tankTargets = { VillageOil, VillageHouse1, VillageChurch, VillageHouse2, VillageHouse4, VillageWell, VillageHouse3 }
	Utils.Do(Map.ActorsWithTag("Village Tank"), function(tank)
		IdleFocusTargets(tank, tankTargets)
	end)

	if not FordFlamer.IsDead then
		IdleHunt(FordFlamer)
	end
end

---@param types string[]
---@param unloadCell cpos
---@param entryCell? cpos
---@return actor helicopter
local function AirliftGDI(types, unloadCell, entryCell)
	Media.PlaySpeechNotification(GDI, "Reinforce")

	-- Favor the beachhead for helicopter entries if secure.
	-- Original behavior for this map is to appear at a random south edge cell.
	if BeachEstablished and not entryCell then
		local offset = Utils.RandomInteger(-7, 8)
		entryCell = BeachEntryCenter.Location + CVec.New(offset, 0)
	end

	local path = { entryCell or FirstInsertionEntry.Location, unloadCell }
	return Reinforcements.ReinforceWithTransport(GDI, "tran.insertion", types, path, { path[1] })[1]
end

local function ReinforceCommando()
	local types =
	{
		easy = { "rmbo.easy" },
		normal = { "rmbo" },
		hard = { "rmbo.hard" }
	}
	local helicopter = AirliftGDI(types[Difficulty], FirstInsertionUnload.Location)

	Trigger.OnPassengerExited(helicopter, function(_, commando)
		-- "Time to rock and roll!"
		commando.GrantCondition("produced")
		CommandoArrived = true
		local camera = Actor.Create("camera", true, { Owner = GDI, Location = FirstInsertionUnload.Location })
		local hunters = Map.ActorsWithTag("Insertion Hunter")

		Utils.Do(hunters, function(h)
			h.Scatter()
			h.AttackMove(FirstInsertionUnload.Location, 2)
			IdleHunt(h)
		end)

		Trigger.OnAllKilled(hunters, function()
			Trigger.AfterDelay(DateTime.Seconds(3), function()
				if camera.IsInWorld then
					camera.Destroy()
				end
			end)
		end)
	end)
end

local function ReinforceBeachGrenadiers()
	if BeachGrenadiersCalled then
		return
	end
	BeachGrenadiersCalled = true

	-- Team "gdi3".
	AirliftGDI({ "e2", "e2", "e2", "e2", "e2" }, Waypoint2.Location)
end

local function ReinforceBeachRifles()
	-- Team "gdi1".
	AirliftGDI({ "e1", "e1", "e1", "e1", "e1" }, Waypoint0.Location)
end

local function ReinforceEastGrenadiers()
	-- Team "gdi7".
	AirliftGDI({ "e2", "e2", "e2", "e2", "e2" }, Waypoint4.Location, FirstInsertionEntry.Location)
end

local function ReinforceOasisGrenadiers()
	-- Team "gdi6".
	AirliftGDI({ "e2", "e2", "e2", "e2", "e2" }, Waypoint3.Location)
end

local function ReinforceBeachTurretGuards()
	-- Team "nod1".
	local types =
	{
		helicopter =
		{
			default = "tran.slowunload",
			hard = "tran.insertion"
		},
		passengers =
		{
			default = { "e3", "e3", "e4", "e4" },
			easy = { "e3", "e3", "e1" }
		}
	}
	local path = { NodHelicopterEntry.Location, Waypoint1.Location }
	local soldiers = Reinforcements.ReinforceWithTransport(Nod, types.helicopter[Difficulty] or types.helicopter.default, types.passengers[Difficulty] or types.passengers.default, path, { path[1] })[2]

	Trigger.OnAnyKilled(soldiers, function()
		Utils.Do(soldiers, IdleHunt)
	end)

	-- In case they survive longer than expected, order them later.
	Utils.Do(soldiers, TagAsDefender)
end

---@param type string
local function ReinforceBeachVehicle(type)
	-- Try to have only one LST (or Easy pair) on the map at once.
	-- This helps reduce traffic jams and overlapping speech.
	if BeachReserved then
		Trigger.AfterDelay(DateTime.Seconds(3), function()
			ReinforceBeachVehicle(type)
		end)

		return
	end

	-- If Easy, toggle this on/off for the next call.
	NextBeachTeamDoubled = Difficulty == "easy" and not NextBeachTeamDoubled
	Media.PlaySpeechNotification(GDI, "Reinforce")
	BeachReserved = true

	if NextBeachTeamDoubled then
		ReinforceWithLandingCraft(GDI, { type }, BeachTeamPaths.Left[1], BeachTeamPaths.Left[2], BeachTeamPaths.Left[3])
		ReinforceWithLandingCraft(GDI, { type }, BeachTeamPaths.Right[1], BeachTeamPaths.Right[2], BeachTeamPaths.Right[3])
		return
	end

	local path = Utils.Random(BeachTeamPaths)
	ReinforceWithLandingCraft(GDI, { type }, path[1], path[2], path[3])
end

local function OnBeachTransportExited()
	BeachReserved = #GDI.GetActorsByType("lst") > 0
	Media.Debug("LST exited. Is beach reserved? " .. tostring(BeachReserved))
	if BeachReserved then
		return
	end

	-- Find vehicles that may be stranded in the water. This is a rare occasion
	-- where an LST blocked by the Gunboat will unload at its current cell.
	local stranded = Utils.Where(GDI.GetActorsByTypes{ "jeep", "msam", "mtnk" }, function(s)
		return s.Location.Y > BeachUnloadCenter.Location.Y
	end)

	Utils.Do(stranded, function(s)
		s.Stop()
		s.Teleport(BeachRallyCenter.Location)
	end)
end

local function PrepareFootprints()
	-- For easier comparison, these are keyed with original trigger names.
	local triggers =
	{
		flre =
		{
			action = OnEastBaseApproached,
			cells =
			{
				CPos.New(44, 37),
				CPos.New(44, 38),
				CPos.New(44, 39),
				CPos.New(44, 40),
				CPos.New(44, 41),
				CPos.New(44, 42),
				CPos.New(44, 43),
				CPos.New(44, 44)
			}
		},
		gdi3 =
		{
			-- Originally triggered by Nod. Nod was not ordered through this
			-- area, which made it easy for the reinforcement to never happen.
			-- I'm guessing this was intended to be a GDI event.
			filter = IsMobileGDI,
			action = ReinforceBeachRifles,
			cells =
			{
				CPos.New(18, 42),
				CPos.New(18, 43),
				CPos.New(18, 44),
				CPos.New(18, 45),
				CPos.New(18, 46),
				CPos.New(18, 47),
				CPos.New(18, 48)
			}
		},
		gdi8 =
		{
			action = function()
				-- Team "gdi4".
				ReinforceBeachVehicle("mtnk")
			end,
			cells =
			{
				CPos.New(24, 32),
				CPos.New(24, 33),
				CPos.New(24, 34),
				CPos.New(24, 35),
				CPos.New(24, 36)
			}
		},
		gdi9 =
		{
			action = ReinforceOasisGrenadiers,
			cells =
			{
				CPos.New(18, 31),
				CPos.New(18, 32),
				CPos.New(18, 33),
				CPos.New(18, 34),
				CPos.New(18, 35),
				CPos.New(18, 36)
			}
		},
		gdid =
		{
			action = function()
				-- Team "gdi5".
				ReinforceBeachVehicle("msam")

				-- If the flare is not already activated, ensure it is now.
				OnEastBaseApproached()
			end,
			cells =
			{
				-- By the east base's sandbagged back door.
				CPos.New(46, 38),
				CPos.New(46, 39),
				CPos.New(46, 40),
				CPos.New(46, 41),
				CPos.New(46, 42),
				-- Between an east base turret and the oasis tank.
				CPos.New(45, 29),
				CPos.New(46, 29),
				CPos.New(47, 29),
				CPos.New(48, 29),
				CPos.New(49, 29),
				CPos.New(50, 29),
				CPos.New(51, 29),
				CPos.New(52, 29)
			}
		},
		nod1 =
		{
			action = ReinforceBeachTurretGuards,
			cells =
			{
				CPos.New(7, 47),
				CPos.New(7, 48),
				CPos.New(7, 49),
				CPos.New(7, 50)
			}
		},
		nod3 =
		{
			action = OnVillageApproached,
			cells =
			{
				CPos.New(35, 45),
				CPos.New(35, 46),
				CPos.New(35, 47),
				CPos.New(35, 48),
				CPos.New(35, 49),
				CPos.New(35, 50)
			}
		},
		nod4 =
		{
			action = function()
				Utils.Do({ WestTank1, WestTank2 }, IdleHunt)
			end,
			cells =
			{
				CPos.New(11, 37),
				CPos.New(12, 37),
				CPos.New(13, 37),
				CPos.New(14, 37),
				CPos.New(15, 37),
				CPos.New(16, 37),
				CPos.New(17, 37)
			}
		},
		nod7 =
		{
			action = OnNorthNodBaseEntered,
			cells =
			{
				CPos.New(50, 6),
				CPos.New(50, 7),
				CPos.New(50, 8),
				CPos.New(50, 9),
				CPos.New(50, 10),
				CPos.New(50, 11),
				CPos.New(50, 12),
				CPos.New(50, 13),
				CPos.New(50, 14)
			}
		},
		prod =
		{
			action = OnEastEdgeEntered,
			cells =
			{
				CPos.New(55, 30),
				CPos.New(56, 30),
				CPos.New(57, 30),
				CPos.New(58, 30),
				CPos.New(59, 30),
				CPos.New(60, 30),
				CPos.New(61, 30)
			}
		}
	}

	Utils.Do(triggers, function(t)
		local activated = false
		local filter = t.filter or IsMobileGDI

		Trigger.OnEnteredFootprint(t.cells, function(a, id)
			if activated or not filter(a) then
				return
			end

			activated = true
			Trigger.RemoveFootprintTrigger(id)
			t.action()
		end)
	end)
end

local function PrepareDamageEvents()
	-- Per original trigger "gdi1", reinforcing team "gdi2".
	Trigger.OnAllKilled({ BeachTurret1, BeachTurret2, BeachTurret4 }, function()
		ReinforceBeachVehicle("jeep")
	end)

	-- Trigger "gdi2" with team "gdi2".
	Trigger.OnKilled(BeachTurret3, function()
		ReinforceBeachVehicle("jeep")
	end)

	-- Trigger "gdi4" with team "gdi3".
	Trigger.OnAllKilled({ VillageOil, VillageHouse1, VillageChurch }, ReinforceBeachGrenadiers)

	-- Ensure grenadiers if the tank is somehow destroyed early in its spree.
	Trigger.OnKilled(VillageFlameTank, ReinforceBeachGrenadiers)

	-- Triggers "gdi5" and "gdi6" with team "gdi4".
	Utils.Do({ Buggy1, Buggy2 }, function(buggy)
		Trigger.OnKilled(buggy, function()
			ReinforceBeachVehicle("mtnk")
		end)
	end)

	-- Trigger "gdi7" with team "gdi4".
	Trigger.OnAllKilled({ WestTank1, WestTank2 }, function()
		ReinforceBeachVehicle("mtnk")
	end)

	-- Triggers "gdia" and "gdib" with team "gdi7".
	Trigger.OnAllKilled(Nod.GetActorsByType("silo"), ReinforceEastGrenadiers)
	Trigger.OnAllKilled({ EastHand, EastPower1, EastPower2 }, ReinforceEastGrenadiers)

	-- Trigger "gdic" with team "gdi5".
	Trigger.OnKilled(OasisTank, function()
		ReinforceBeachVehicle("msam")
	end)

	-- Not original behavior but if a player seems to be destroying the
	-- objective buildings from range, act as if the gate has been passed.
	Trigger.OnAnyKilled(GetNorthBase(false), OnNorthNodBaseEntered)

	local northTurretEvents =
	{
		-- Trigger "nod6" with team "nod6".
		{
			turret = NorthTurret1,
			infantry = { "e3", "e3" },
			vehicles = { "bggy" }
		},
		-- Trigger "nod5", with team "nod4".
		{
			turret = NorthTurret2,
			infantry = { "e3", "e3", "e1", "e1" }
		}
	}

	Utils.Do(northTurretEvents, function(nte)
		local activated = false

		Trigger.OnDamaged(nte.turret, function()
			if activated then
				return
			end

			activated = true
			BuildInfantry(nte.infantry)
			BuildVehicles(nte.vehicles)
		end)
	end)
end

--- Order certain units to begin area guarding.
local function PrepareAreaGuards()
	local teams =
	{
		{
			actors = Map.ActorsWithTag("East Base Infantry"),
			center = FlareEntry.CenterPosition,
			range = 5,
			hunt = true
		},
		{
			actors = { BeachRocket1, BeachRocket2 },
			center = BeachRocket2.CenterPosition
		},
		{
			actors = { FordRocket1, FordRocket2 },
			center = FordRocket2.CenterPosition
		},
		{
			actors = { OasisTank }
		},
		{
			actors = { EastBaseTank }
		},
	}

	Utils.Do(teams, function(team)
		local radius = WDist.FromCells(team.range or 7)
		local center = team.center or team.actors[1].CenterPosition
		GuardArea(team.actors, center, radius, team.hunt)

		if #team.actors > 1 then
			return
		end

		Trigger.OnDamaged(team.actors[1], function(actor, attacker)
			if actor.IsDead or attacker.Type ~= "msam" then
				return
			end

			actor.Hunt()
		end)
	end)
end

local function CheckBaseObjective()
	-- Refresh the target list. There may be new buildings on Hard.
	local baseActors = GetNorthBase(true)
	if #baseActors > 0 then
		Trigger.OnAllKilled(baseActors, CheckBaseObjective)
		return
	end

	VictoryStarted = true
	GDI.MarkCompletedObjective(DestroyNorthBase or GDI.AddPrimaryObjective("destroy-nod-base-north"))
end

local function PrepareObjectives()
	InitObjectives(GDI)
	Trigger.OnAllKilled(GetNorthBase(true), CheckBaseObjective)

	Trigger.OnAllKilled(Map.ActorsWithTag("Beach Defender"), function()
		BeachEstablished = true
		DestroyNorthBase = AddPrimaryObjective(GDI, "destroy-nod-base-north")
		GDI.MarkCompletedObjective(EstablishBeach)
	end)
end

WorldLoaded = function()
	-- Original is 4000 but on some testing runs, repair
	-- costs were enough to prevent tank production.
	Nod.Cash = 6000
	Camera.Position = FirstInsertionUnload.CenterPosition
	PrepareObjectives()
	PrepareDamageEvents()
	PrepareFootprints()
	PrepareAreaGuards()

	-- The original tank tries to hunt the pre-placed Commando.
	InsertionFlameTank.Move(FirstInsertionUnload.Location)
	ReinforceCommando()

	local defendedBuildings = Utils.Where(Nod.GetActorsByTypes({ "afld", "fact", "gun", "hand", "hq", "nuke", "silo" }), function(a)
		if a.Type == "gun" then
			-- Ignore most Turrets except the north edge ones.
			return a.Location.Y < Waypoint6.Location.Y
		end

		return true
	end)

	DefendBase(defendedBuildings, DateTime.Seconds(10))
	RepairNamedActors(Nod, 0.75)

	Trigger.OnDiscovered(VillageChurch, function(_, discoverer)
		if ChurchDiscovered or discoverer ~= GDI then
			return
		end

		ChurchDiscovered = true
		OnChurchDiscovered()
	end)

	Trigger.OnEnteredFootprint({ BeachEntryLeft.Location, BeachEntryCenter.Location, BeachEntryRight.Location }, function(a)
		if a.Type == "lst" and a.HasPassengers then
			Trigger.OnRemovedFromWorld(a, OnBeachTransportExited)
		end
	end)

	if Difficulty ~= "hard" then
		return
	end

	Nod.Cash = 8500
	Actor.Create("ltnk", true, { Owner = Nod, Location = VillageTankEntry.Location, Facing = Angle.NorthEast, ScriptTags = { "Village Tank" } })
	Actor.Create("ftnk", true, { Owner = Nod, Location = NorthTankEntry.Location, Facing = Angle.East })
	local eastArtillery = Actor.Create("arty", true, { Owner = Nod, Location = EastArtilleryEntry.Location, Facing = Angle.SouthEast })
	eastArtillery.Stance = "Defend"

	Trigger.OnBuildingPlaced(Nod, function(_, building)
		-- Note that the builder module is unlikely to have space for this.
		if building.Type == "afld" then
			Airstrip = building
			BuildVehicles()
		elseif building.Type == "hand" then
			NorthHand = building
			BuildInfantry()
		end

		RepairBuilding(Nod, building, 0.75)
		DefendBase({ building }, DateTime.Seconds(10))
	end)
end

Tick = function()
	if VictoryStarted and Nod.HasNoRequiredUnits() then
		GDI.MarkCompletedObjective(EliminateNod)
	end

	if DefeatStarted then
		return
	end

	if CommandoArrived and not BeachReserved and GDI.HasNoRequiredUnits() then
		Utils.Do({ EstablishBeach, DestroyNorthBase }, function(o)
			if DefeatStarted or GDI.IsObjectiveCompleted(o) then
				return
			end

			DefeatStarted = true
			GDI.MarkFailedObjective(o)
		end)
	end
end
