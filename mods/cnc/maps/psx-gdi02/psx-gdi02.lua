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

local EvacuateMobius = AddPrimaryObjective(GDI, "clear-sams-evacuate-mobius")
local EvacuatorType = "tran.extraction"
local DefeatStarted = false
local SamsCleared = false
local GlobalHuntStarted = false

--- Has an attacked Nod building recently called for help?
local DefendersAlerted = false

--- Has Mobius been revealed at the hospital by GDI or Nod?
local MobiusReached = false

--- The actor carrying Mobius, if any. This helps track the doctor's
--- "real" position since transported actors are not in the world.
---@type actor?
local MobiusTransport = nil

local NukeTimers =
{
	default = DateTime.Minutes(15),
	easy = DateTime.Minutes(20),
	hard = DateTime.Minutes(7)
}

local RemainingTime = NukeTimers[Difficulty] or NukeTimers.default
local CountdownEnabled = true
local TimerColor = Nod.Color

---@param actor actor
---@return boolean
local function IsMobileGDI(actor)
	return actor.Owner == GDI and actor.HasProperty("Move")
end

---@param actor actor
---@return boolean
local function IsMobileNod(actor)
	return actor.Owner == Nod and actor.HasProperty("Move")
end

--- Is Mobius revealed, alive, and unguarded by SAM Sites?
---@return boolean
local function IsExtractionReady()
	return SamsCleared and MobiusReached and not DefeatStarted and not Mobius.IsDead
end

---@param actor actor
local function TagAsDefender(actor)
	actor.AddTag("Base Defender")
end

---@param time? number
local function UpdateTimerText(time)
	if not CountdownEnabled then
		UserInterface.SetMissionText("")
		return
	end

	local text = UserInterface.GetFluentMessage("nod-missile-attack-in", { ["time"] = Utils.FormatTime(time or RemainingTime) })
	UserInterface.SetMissionText(text, TimerColor)
end

---@param transport actor
local function LeaveWithMobius(transport)
	if transport.Location == Waypoint1.Location then
		transport.Move(ExtractionTurn.Location)
	end

	if transport.Location ~= ExtractionExit.Location then
		transport.Move(ExtractionExit.Location)
		return
	end

	MobiusTransport = nil
	transport.Destroy()
	GDI.MarkCompletedObjective(EvacuateMobius)
	CountdownEnabled = false
	UpdateTimerText()
end

--- Prepare this actor to carry Mobius and track his movements.
---@param transport actor
local function PrepareTransport(transport)
	Trigger.OnPassengerEntered(transport, function(_, passenger)
		if passenger.Type ~= "moebius" then
			return
		end

		MobiusTransport = transport
	end)

	Trigger.OnPassengerExited(transport, function(_, passenger)
		if passenger.Type ~= "moebius" then
			return
		end

		MobiusTransport = nil
	end)

	if transport.Type ~= EvacuatorType then
		return
	end

	Trigger.OnIdle(transport, function(t)
		if t ~= MobiusTransport or not t.HasPassengers then
			return
		end

		LeaveWithMobius(t)
	end)
end

local function SendExtractionHelicopter()
	local helicopter = Reinforcements.Reinforce(GDI, { EvacuatorType }, { Waypoint9.Location, Waypoint7.Location, Waypoint1.Location }, 0, function(a)
		a.Land(Waypoint1)
	end)[1]

	Media.PlaySpeechNotification(GDI, "Reinforce")
	PrepareTransport(helicopter)

	Trigger.OnKilled(helicopter, function()
		Trigger.AfterDelay(DateTime.Seconds(6), SendExtractionHelicopter)
	end)
end

--- Order a unit to hunt Mobius or his current transport.
---@param hunter actor
local function HuntMobius(hunter)
	if not MobiusReached and not GlobalHuntStarted then
		hunter.AttackMove(Waypoint2.Location)
		hunter.AttackMove(Waypoint3.Location)
	end

	Trigger.OnIdle(hunter, function()
		if GlobalHuntStarted or Mobius.IsDead then
			hunter.Hunt()
			return
		end

		if not MobiusReached then
			-- Move toward the bridge. Once it is approached by either faction,
			-- Mobius loses his neutrality and we can then AttackMove on him.
			hunter.AttackMove(Waypoint22.Location, 2)
			return
		end

		if MobiusTransport ~= nil and MobiusTransport.IsInWorld then
			hunter.AttackMove(MobiusTransport.Location, 2)
			return
		end

		if MobiusTransport == nil then
			-- Original behavior seems closer to Move where they would ignore
			-- GDI if possible, but it's easy to block units on the bridge.
			hunter.AttackMove(Mobius.Location, 2)
		end
	end)
end

local function OnHospitalApproached()
	if Mobius.IsDead or MobiusReached then
		return
	end

	MobiusReached = true
	Mobius.Owner = GDI
	local flare = Actor.Create("flare", true, { Owner = GDI, Location = FlareEntry.Location })

	if IsExtractionReady() then
		SendExtractionHelicopter()
	end

	Trigger.OnDamaged(HospitalTree2, function(_, attacker)
		-- Ignore if this does not appear to be a nuke.
		if attacker.Type ~= "player" or attacker.Owner ~= Nod or not flare.IsInWorld then
			return
		end

		flare.Destroy()
	end)
end

---@param mobius actor
local function OnMobiusKilled(mobius)
	DefeatStarted = true

	-- Pause for "Civilian killed."
	Trigger.AfterDelay(39, function()
		GDI.MarkFailedObjective(EvacuateMobius)
	end)

	if not MobiusReached then
		Camera.Position = Waypoint22.CenterPosition
		return
	end

	if MobiusTransport ~= nil then
		Camera.Position = MobiusTransport.CenterPosition
		return
	end

	Camera.Position = mobius.CenterPosition
end

---@param building actor
local function DefendBuilding(building)
	Trigger.OnDamaged(building, function(_, attacker)
		if DefendersAlerted or attacker.IsDead or attacker.Owner == building.Owner or attacker.Type == "player" then
			return
		end

		DefendersAlerted = true
		MoveAndHunt(Map.ActorsWithTag("Base Defender"), { attacker })

		Trigger.AfterDelay(DateTime.Seconds(15), function()
			DefendersAlerted = false
		end)
	end)
end

local function PrepareStartGuards()
	local eastGuards = Map.ActorsWithTag("East Start Guard")
	local eastGuardsActivated = false
	local eastGuardsDamaged = false

	-- Close match for LTNK area guard range. Original E4 range was about half.
	Trigger.OnEnteredProximityTrigger(EastStartGuardTank.CenterPosition, WDist.FromCells(7), function(a, id)
		if not IsMobileGDI(a) then
			return
		end

		Trigger.RemoveProximityTrigger(id)

		if not eastGuardsActivated then
			eastGuardsActivated = true
			Utils.Do(eastGuards, IdleHunt)
		end
	end)

	Utils.Do(eastGuards, function(guard)
		Trigger.OnDamaged(guard, function()
			if eastGuardsDamaged then
				return
			end

			if not eastGuardsActivated then
				eastGuardsActivated = true
				Utils.Do(eastGuards, IdleHunt)
			end

			if not eastGuardsDamaged then
				eastGuardsDamaged = true
				local entryCell = EastNodEntry.Location + CVec.New(0, Utils.RandomInteger(-1, 2))
				local buggy = Actor.Create("bggy", true, { Owner = Nod, Location = entryCell, Facing = Angle.West, ScriptTags = { "Base Defender" } })
				buggy.AttackMove(Waypoint0.Location)
			end
		end)
	end)
end

local function ReinforceStartingUnits()
	Media.PlaySpeechNotification(GDI, "Reinforce")
	StartCarrier.Move(StartCarrierTurn1.Location)
	StartCarrier.Wait(DateTime.Seconds(1))
	StartCarrier.Move(StartCarrierTurn2.Location)
	StartCarrier.Move(StartCarrierRally1.Location)

	Utils.Do(GDI.GetActorsByTypes({ "e1", "e2" }), function(a)
		a.Move(a.Location + CVec.New(0, -2))
	end)

	-- The support units further below were originally MSAMs. In ORA,
	-- they outrange Obelisks and seem a rough fit for the map's design.
	local supportType = "jeep"
	if Difficulty == "easy" then
		supportType = "mtnk"
	end

	local reinforcements =
	{
		westTank1 =
		{
			type = "mtnk",
			path = { WestStartEntry1.Location, WestStartRally1.Location }
		},
		westTank2 =
		{
			type = "mtnk",
			path = { WestStartEntry2.Location, WestStartRally2.Location }
		},
		westMammoth1 =
		{
			type = "htnk",
			path = { WestStartEntry1.Location, WestStartRally3.Location },
			delay = DateTime.Seconds(3)
		},
		westMammoth2 =
		{
			type = "htnk",
			path = { WestStartEntry2.Location, WestStartRally4.Location },
			delay = DateTime.Seconds(3)
		},
		eastCarrier =
		{
			type = "apc",
			path = { EastStartEntry3.Location, StartCarrierTurn4.Location, StartCarrierTurn3.Location, StartCarrierRally2.Location }
		},
		eastSupport1 =
		{
			type = supportType,
			path = { EastStartEntry1.Location, StartSupportRally1.Location },
			delay = DateTime.Seconds(2)
		},
		eastSupport2 =
		{
			type = supportType,
			path = { EastStartEntry2.Location, StartSupportRally2.Location },
			delay = DateTime.Seconds(2)
		}
	}

	Utils.Do(reinforcements, function(r)
		Trigger.AfterDelay(r.delay or 0, function()
			Reinforcements.Reinforce(GDI, { r.type }, r.path)
		end)
	end)

	Trigger.AfterDelay(DateTime.Seconds(6), function()
		Utils.Do(GDI.GetActorsByType("apc"), PrepareTransport)
	end)
end

local function PrepareLaunch()
	DateTime.TimeLimit = RemainingTime
	UpdateTimerText()

	Trigger.AfterDelay(RemainingTime - DateTime.Seconds(121), function()
		if not CountdownEnabled then
			return
		end

		TimerColor = HSLColor.Yellow
	end)

	Trigger.OnTimerExpired(function()
		if GDI.IsObjectiveCompleted(EvacuateMobius) or DefeatStarted or Temple.IsDead then
			return
		end

		TimerColor = Nod.Color
		UpdateTimerText(0)
		CountdownEnabled = false
		Trigger.AfterDelay(DateTime.Seconds(6), UpdateTimerText)
		Media.PlaySpeechNotification(GDI, "NuclearWarheadApproaching")

		-- It was technically possible for Nod to nuke other things, but it
		-- would be overkill to emulate that here. The normal nuke target was
		-- always the most valuable "enemy" structure: the hospital.
		Temple.ActivateNukePower(FlareEntry.Location)
	end)

	-- Unlikely but possible, as it was in the original. Covered just in case.
	Trigger.OnKilled(Temple, function()
		if not CountdownEnabled then
			return
		end

		DateTime.TimeLimit = 0
		TimerColor = HSLColor.LightGreen
		UpdateTimerText()
		CountdownEnabled = false
		Trigger.AfterDelay(DateTime.Seconds(6), UpdateTimerText)
	end)
end

---@param types? string[]
---@param action? fun(actor: actor)
local function BuildVehicles(types, action)
	if Airstrip.IsDead then
		return
	end

	Airstrip.Build(types or { "bggy" }, function(actors)
		Utils.Do(actors, action or TagAsDefender)

		if Difficulty ~= "hard" then
			return
		end

		Trigger.AfterDelay(DateTime.Seconds(30), function()
			local vehicles = Nod.GetActorsByTypes({ "arty", "bggy", "ftnk" })

			if #vehicles > 0 then
				Trigger.OnAllKilled(vehicles, BuildVehicles)
				return
			end

			BuildVehicles()
		end)
	end)
end

local function BuildInfantry()
	if Hand.IsDead or Hand.IsProducing("e1") then
		return
	end

	-- Types based on the original "nod2" team.
	Hand.Build({ Utils.Random({ "e1", "e1", "e3", "e3", "e4" }) }, function(actors)
		Utils.Do(actors, function(a)
			a.AddTag("Base Defender")
			a.AddTag("Base Infantry")
			Trigger.OnKilled(a, BuildInfantry)
		end)

		if #Map.ActorsWithTag("Base Infantry") < 5 then
			BuildInfantry()
		end
	end)
end

local function BuildPower()
	local buildLimit = 4
	local builder = Nod.GrantCondition("nod-builder-enabled")

	Trigger.OnBuildingPlaced(Nod, function(_, building)
		buildLimit = buildLimit - 1
		RepairBuilding(Nod, building, 0.75)

		if buildLimit == 0 then
			Nod.RevokeCondition(builder)
		end
	end)
end

local function PrepareFootprints()
	-- For easier comparison, these are keyed with original trigger names.
	local triggers =
	{
		flr1 =
		{
			-- The check in this function works like the "delx" footprint did.
			action = OnHospitalApproached,
			cells =
			{
				CPos.New(9, 7),
				CPos.New(10, 7),
				CPos.New(11, 7),
				CPos.New(10, 8),
				CPos.New(11, 8)
			}
		},
		hunt =
		{
			action = function()
				Utils.Do(Nod.GetGroundAttackers(), IdleHunt)
				GlobalHuntStarted = true
			end,
			cells =
			{
				CPos.New(16, 8),
				CPos.New(17, 8),
				CPos.New(18, 8),
				CPos.New(18, 9),
				CPos.New(18, 10),
				CPos.New(18, 11)
			}
		},
		nod3 =
		{
			action = function()
				-- Team "nod3".
				BuildVehicles({ "ftnk", "arty" }, HuntMobius)
			end,
			cells =
			{
				CPos.New(32, 11),
				CPos.New(33, 11),
				CPos.New(34, 11),
				CPos.New(35, 11),
				CPos.New(36, 11)
			}
		},
		xxxx =
		{
			action = OnHospitalApproached,
			filter = IsMobileNod,
			cells =
			{
				CPos.New(16, 8),
				CPos.New(16, 9),
				CPos.New(16, 10),
				CPos.New(16, 11),
				CPos.New(16, 12)
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

local function PrepareNodBuildings()
	Trigger.OnAllKilled(Nod.GetActorsByType("sam"), function()
		SamsCleared = true

		if IsExtractionReady() then
			SendExtractionHelicopter()
		end
	end)

	local buildings = Utils.Where(Nod.GetActors(), function(b)
		return b.HasProperty("StartBuildingRepairs")
	end)

	local defendedBuildings = Utils.Where(buildings, function(b)
		return not b.HasProperty("Attack")
	end)

	-- Original trigger "prod".
	Trigger.OnAnyKilled(buildings, function()
		BuildInfantry()

		-- A grace period is important to GDI units leaving the start area.
		-- The bot may otherwise rebuild power fast enough to be an issue.
		Trigger.AfterDelay(DateTime.Seconds(30), BuildPower)
	end)

	Utils.Do(defendedBuildings, DefendBuilding)
	RepairNamedActors(Nod, 0.75)
	Nod.Cash = 7000

	if Difficulty == "hard" then
		Nod.Cash = 9000
	end

	if Difficulty == "easy" then
		Utils.Do({ SouthObelisk1, SouthObelisk2, NorthObelisk1, NorthObelisk2 }, function(obelisk)
			obelisk.GrantCondition("self-revealing")
		end)

		return
	end

	Utils.Do({ SouthObelisk1, SouthObelisk2 }, function(obelisk)
		-- A GDI-owned civilian revealed these on the '95 map once it was
		-- fired upon. There was a civilian team for a similar reveal
		-- at the northern defenses, but the team was unused.
		Actor.Create("camera.obelisk", true, { Owner = GDI, Location = obelisk.Location })
	end)
end

WorldLoaded = function()
	InitObjectives(GDI)
	Camera.Position = CameraStart.CenterPosition

	PrepareFootprints()
	PrepareStartGuards()
	PrepareLaunch()
	PrepareNodBuildings()
	Trigger.OnKilled(Mobius, OnMobiusKilled)
	ReinforceStartingUnits()

	-- These will (slowly) respond to an attack on the southern power stations.
	Reinforcements.Reinforce(Nod, { "e1", "e1", "e3" }, { Hand.Location + CVec.New(0, 2) }, 0, function(actor)
		actor.AddTag("Base Defender")
		actor.Scatter()
	end)

	if Difficulty == "easy" then
		Utils.Do(Map.ActorsWithTag("Removable West Rocket"), function(rwr)
			rwr.Destroy()
		end)
	end
end

Tick = function()
	if GDI.IsObjectiveCompleted(EvacuateMobius) or DefeatStarted then
		return
	end

	if GDI.HasNoRequiredUnits() then
		DefeatStarted = true
		GDI.MarkFailedObjective(EvacuateMobius)
		CountdownEnabled = false
		UpdateTimerText()
		return
	end

	if RemainingTime >= 0 and CountdownEnabled then
		if (RemainingTime % DateTime.Seconds(1)) == 0 then
			UpdateTimerText()
		end

		RemainingTime = RemainingTime - 1
	end
end
