--[[
   Copyright (c) The OpenRA Developers and Contributors
   This file is part of OpenRA, which is free software. It is made
   available to you under the terms of the GNU General Public License
   as published by the Free Software Foundation, either version 3 of
   the License, or (at your option) any later version. For more
   information, see COPYING.
]]
BadGuy = Player.GetPlayer("BadGuy")
England = Player.GetPlayer("England")
Greece = Player.GetPlayer("Greece")
GoodGuy = Player.GetPlayer("GoodGuy")
Neutral = Player.GetPlayer("Neutral")
USSR = Player.GetPlayer("USSR")

ForestTeam = { ForestPatroller1, ForestPatroller2, ForestPatroller3, ForestPatroller4, ForestPatroller5, ForestPatroller6, ForestPatroller7, ForestPatroller8 }
BlockerTeam = { BlockerGuard1, BlockerGuard2, BlockerTank }
SoutheastTurretTeam = { SoutheastTurretRifle1, SoutheastTurretRifle2, SoutheastTurretRifle3 }
Hostages = { Hostage1, Hostage2, Hostage3, Hostage4, Hostage5 }

TimerColor = HSLColor.White
TimeRemaining = 0

TanyaType = "e7.noautotarget"
if Difficulty == "easy" then
	TanyaType = "e7"
end

WorldLoaded = function()
	Camera.Position = TanyaDrop.CenterPosition
	SpawnPlayerCamera(TanyaDrop.Location, DateTime.Seconds(20))

	Trigger.AfterDelay(1, function()
		Media.PlaySpeechNotification(Greece, "TimerStarted")
	end)

	StartSoldier.Move(WestRoadRally.Location)
	if Difficulty == "hard" then
		StartSoldier.CallFunc(ReinforceStartSoldiers)
	end

	ReinforceHardTeams()
	PrepareBadGuy()
	ReinforceTanya()
	CreateInitialTriggers()
	SetObjectives()
	CheckSovietDestruction()
end

SetObjectives = function()
	InitObjectives(Greece)
	if Difficulty == "hard" then
		SaveAllHostages = AddPrimaryObjective(Greece, "keep-all-hostages-alive")
	end
	FreeTheHostages = AddPrimaryObjective(Greece, "free-hostages")
	EscortTheHostages = AddPrimaryObjective(Greece, "get-hostages-to-church")
	SignalReinforcements = AddSecondaryObjective(Greece, "signal-reinforcements")
	if not SaveAllHostages then
		SaveAllHostages = AddSecondaryObjective(Greece, "keep-all-hostages-alive")
	end
	DestroySoviets = AddPrimaryObjective(Greece, "destroy-soviet-units-infrastructure")
	DestroyAllies = AddPrimaryObjective(USSR, "")
end

CheckSovietDestruction = function()
	local destroyed = USSR.HasNoRequiredUnits() and BadGuy.HasNoRequiredUnits()
	if not destroyed then
		Trigger.AfterDelay(DateTime.Seconds(1), CheckSovietDestruction)
		return
	end

	Greece.MarkCompletedObjective(DestroySoviets)
	if not Greece.IsObjectiveFailed(SaveAllHostages) then
		Greece.MarkCompletedObjective(SaveAllHostages)
	end
end

CheckAlliedDestruction = function()
	if #Greece.GetGroundAttackers() == 0 then
		AlliedDefeat()
	end
end

AlliedDefeat = function(objective, delay)
	if AlliesDefeated then
		return
	end
	AlliesDefeated = true
	delay = delay or DateTime.Seconds(1)

	if not Greece.IsObjectiveCompleted(FreeTheHostages) then
		StopCountdown()
	end

	Trigger.AfterDelay(delay, function()
		if not objective then
			USSR.MarkCompletedObjective(DestroyAllies)
			return
		end
		Greece.MarkFailedObjective(objective)
	end)
end

CheckEscortObjective = function()
	if Greece.IsObjectiveCompleted(EscortTheHostages) then
		return
	end

	local liveHostages = Utils.Where(Hostages, IsAlive)
	if Church.PassengerCount < #liveHostages then
		return
	end
	OnHostagesEscorted()
end

CreateInitialTriggers = function()
	PrepareChurch()
	PrepareHostages()
	PrepareReveals()
	PrepareSovietGuards()
	PrepareForestEncounter()
	PrepareChronoTanks()
	PrepareBlockers()

	Trigger.OnKilled(ForwardCommand, function()
		FireSale(USSR)
	end)

	local sams = { WestSam, EastSam }
	Trigger.OnAllKilled(sams, ReinforceLongbows)

	local guideHouseAttackers = { GuideRifleWest, GuideRifleEast }
	Trigger.OnAllKilled(guideHouseAttackers, OnGuideRiflesKilled)

	Trigger.OnEnteredProximityTrigger(TanyaDrop.CenterPosition, WDist.FromCells(4), function(actor, id)
		if not (Greece.IsObjectiveCompleted(EscortTheHostages) and actor.Type == TanyaType) then
			return
		end
		Trigger.RemoveProximityTrigger(id)
		SignalAllies()
	end)

	local prisonApproached = false
	Trigger.OnEnteredProximityTrigger(Prison.CenterPosition, WDist.FromCells(8), function(actor, id)
		if prisonApproached or not IsGuideOrAllies(actor) then
			return
		end
		prisonApproached = true
		Trigger.RemoveProximityTrigger(id)
		ReinforceGuardHouse(actor.Type)
		BlockersToGuideHouse()
	end)

	local prisonBarrels = { PrisonBarrel1, PrisonBarrel2, PrisonBarrel3, PrisonBarrel4 }
	Trigger.OnAllKilled(prisonBarrels, function()
		local targets = { Prison, Executioner }
		Utils.Do(targets, function(target)
			if target.IsDead then
				return
			end
			target.Kill("FireDeath")
		end)
	end)
end

PrepareHostages = function()
	ScheduleExecutions()
	Trigger.OnKilled(Executioner, FreeHostages)
	Trigger.OnAllKilled(Hostages, OnHostagesKilled)
	Trigger.OnAnyKilled(Hostages, OnAnyHostageKilled)

	-- Keep hostages wandering, but only inside the pen.
	Trigger.OnEnteredProximityTrigger(Executioner.CenterPosition, WDist.FromCells(2), function(actor, id)
		if Executioner.IsDead then
			Trigger.RemoveProximityTrigger(id)
			return
		end
		if not (actor.Owner == Neutral) then
			return
		end

		actor.Stop()
		actor.Move(HostageCenter.Location)
	end)
end

Tick = function()
	if TimeRemaining < 1 then
		return
	end
	TimeRemaining = TimeRemaining - 1

	if not (TimeRemaining % DateTime.Seconds(1) == 0) then
		return
	end

	local text = UserInterface.Translate("hostage-dies-in", { ["time"] = Utils.FormatTime(TimeRemaining) } )
	UserInterface.SetMissionText(text, TimerColor)
end

PrepareCountdown = function(interval)
	local text = UserInterface.Translate("hostage-dies-in", { ["time"] = Utils.FormatTime(interval) } )
	UserInterface.SetMissionText(text, TimerColor)
	DateTime.TimeLimit = 1

	Trigger.OnTimerExpired(function()
		local liveHostages = Utils.Where(Hostages, IsAlive)
		if #liveHostages > 1 then
			ResetCountdown(interval)
			return
		end
		UserInterface.SetMissionText("")
	end)
end

ResetCountdown = function(interval)
	DateTime.TimeLimit = interval
	TimeRemaining = interval
	TimerColor = HSLColor.White
	Trigger.AfterDelay(interval - DateTime.Minutes(2), function()
		TimerColor = USSR.Color
	end)
end

StopCountdown = function()
	DateTime.TimeLimit = 0
	TimeRemaining = 0
	UserInterface.SetMissionText("")
end

ScheduleExecutions = function()
	local intervals =
	{
		easy = 5,
		normal = 4,
		hard = 3,
	}
	-- -1 tick avoids the redundant x-minute warning speech upon timer refresh.
	local interval = DateTime.Minutes(intervals[Difficulty]) - 1
	local delay = 0

	PrepareCountdown(interval)

	Utils.Do(Hostages, function(hostage)
		delay = delay + interval

		Trigger.AfterDelay(delay, function()
			ExecuteHostage(hostage)
		end)
	end)
end

ExecuteHostage = function(hostage)
	if Executioner.IsDead then
		return
	end

	Media.PlaySoundNotification(Greece, "HostageShot")
	hostage.Kill("DefaultDeath")
end

FreeHostages = function()
	ReinforceNorthChinook()
	StopCountdown()
	Greece.MarkCompletedObjective(FreeTheHostages)

	Utils.Do(Hostages, function(hostage)
		if hostage.IsDead then
			return
		end
		hostage.Owner = England

		Trigger.OnKilled(Tanya, function()
			if hostage.IsDead then
				return
			end
			hostage.Panic()
		end)

		Trigger.OnIdle(hostage, function()
			hostage.Guard(Tanya)
		end)
	end)

	local guide = GetGuide()
	if not guide then
		return
	end

	Trigger.OnIdle(guide, function()
		guide.Guard(Tanya)
	end)
end

PrepareForestEncounter = function()
	local patrolPassed = false

	local forestFoot = Trigger.OnEnteredFootprint( { ForestSafetyCheck.Location }, function(actor, id)
		if patrolPassed or not (actor.Owner == USSR) then
			return
		end
		patrolPassed = true
		Trigger.RemoveFootprintTrigger(id)
		GuideToVillage()
	end)

	Trigger.OnAllKilled(ForestTeam, function()
		if patrolPassed then
			return
		end
		patrolPassed = true
		Trigger.RemoveFootprintTrigger(forestFoot)
		GuideToVillage()
	end)

	Trigger.OnEnteredFootprint( { ForestCenter.Location }, function(actor, id)
		if not IsGuide(actor) then
			return
		end
		Trigger.RemoveFootprintTrigger(id)
		Trigger.AfterDelay(0, function()
			GuideToHideout(actor)
		end)
	end)

	Trigger.OnExitedFootprint( { ForestHideout.Location }, function(actor, id)
		if Executioner.IsDead or not (IsAlive(actor) and IsGuide(actor)) then
			return
		end
		Trigger.RemoveFootprintTrigger(id)
		Media.DisplayMessage(UserInterface.Translate("guide-follow-me"), actor.TooltipName)
	end)

	Trigger.OnEnteredFootprint( { ForestSouthwest.Location }, function(actor, id)
		if not (actor.Type == "dog") then
			return
		end
		Trigger.RemoveFootprintTrigger(id)
		Trigger.AfterDelay(DateTime.Seconds(1), function()
			Media.PlaySoundNotification(Greece, "DogWhine")
		end)
	end)
end

PrepareChronoTanks = function()
	local sides =
	{
		westRoad =
		{
			cells = { CPos.New(41, 65), CPos.New(42, 65), CPos.New(43, 65), CPos.New(44, 65), CPos.New(45, 65), CPos.New(46, 65) },
			spawns = { ChronoEntryWest1.Location, ChronoEntryWest2.Location }
		},
		eastRoad =
		{
			cells = { CPos.New(66, 70), CPos.New(66, 71), CPos.New(67, 71), CPos.New(68, 71), CPos.New(69, 71), CPos.New(70, 71), CPos.New(71, 71), CPos.New(72, 71), CPos.New(72, 71), CPos.New(73, 71) },
			spawns = { ChronoEntryEast1.Location, ChronoEntryEast2.Location }
		}
	}

	Utils.Do(sides, function(side)
		Trigger.OnEnteredFootprint(side.cells, function(actor, id)
			if not (Executioner.IsDead and actor.Owner == Greece) then
				return
			end
			Trigger.RemoveFootprintTrigger(id)
			ReinforceChronoTanks(side.spawns)
		end)
	end)
end

PrepareSovietGuards = function()
	Utils.Do(BadGuy.GetGroundAttackers(), function(soviet)
		Trigger.OnDamaged(soviet, function(_, attacker)
			if attacker.Type == "dtrk" or not (attacker.Owner == Greece) then
				return
			end
			IdleHunt(soviet)
		end)
	end)

	local beachAlerted = false
	local beachGroup = { SouthBeachGuard1, SouthBeachGuard2, SouthBeachGuard3, SouthBeachGuard4 }
	Trigger.OnAllKilled(beachGroup, SovietSouthBeachCamera.Destroy)

	Trigger.OnAnyKilled(beachGroup, function()
		if beachAlerted or Tanya.IsDead then
			return
		end
		beachAlerted = true
		GroupIdleHunt(beachGroup)

		Utils.Do(beachGroup, function(actor)
			if actor.IsDead then
				return
			end
			actor.Attack(Tanya)
		end)
	end)

	local others =
	{
		{ RoadTurretRifle1, RoadTurretRifle2, RoadTurretWest, RoadTurretEast },
		{ GuideRifleWest, GuideRifleEast },
		{ FarmGuard1, FarmGuard2, FarmGuard3, FarmGuard4 },
		SoutheastTurretTeam,
		ForestTeam,
		BlockerTeam
	}

	Utils.Do(others, function(group)
		GroupHuntOnDamaged(group, Greece)
	end)
end

PrepareMainReveals = function()
	local mainReveals =
	{
		roadTurrets =
		{
			cells = { CPos.New(36, 71), CPos.New(36, 72), CPos.New(36, 73), CPos.New(37, 73), CPos.New(38, 73), CPos.New(39, 73), CPos.New(40, 73), CPos.New(41, 73), CPos.New(42, 73), CPos.New(43, 73), CPos.New(44, 73), CPos.New(45, 73), CPos.New(46, 73), CPos.New(47, 73) },
			location = RoadTurretReveal.Location
		},
		southBeachBarrels =
		{
			cells = { CPos.New(51, 75), CPos.New(51, 76), CPos.New(51, 77), CPos.New(51, 78), CPos.New(51, 79) },
			location = SouthBeachReveal.Location,
			onTriggered = SovietStartCamera.Destroy
		},
		southeastTurret =
		{
			cells = { CPos.New(68, 82), CPos.New(68, 83), CPos.New(68, 84), CPos.New(68, 85), CPos.New(68, 86), CPos.New(68, 87), CPos.New(68, 88), CPos.New(68, 89) },
			location = SoutheastTurret.Location,
			onTriggered = function()
				local dogs = Map.ActorsWithTag("TurretDog")
				GroupAttackMove(dogs, SoutheastTurret.Location + CVec.New(0, 1))
			end
		},
		samFence =
		{
			cells = { CPos.New(69, 74), CPos.New(70, 74), CPos.New(71, 74), CPos.New(72, 74), CPos.New(73, 74), CPos.New(74, 74) },
			location = SamFenceReveal.Location,
			onTriggered = ReinforceVillagePatrol
		},
		riverHouse =
		{
			cells = { CPos.New(80, 79), CPos.New(80, 80), CPos.New(80, 81), CPos.New(80, 82), CPos.New(80, 83) },
			location = GuideHouseReveal.Location,
			onTriggered = function()
				ReinforceVillagePatrol()
				OrderGuideRifles()
			end
		},
		forest =
		{
			cells = { CPos.New(85, 62), CPos.New(86, 62), CPos.New(87, 62), CPos.New(88, 62), CPos.New(89, 62), CPos.New(90, 62), CPos.New(91, 62), CPos.New(92, 62), CPos.New(93, 62), CPos.New(94, 62) },
			location = ForestCenter.Location,
			duration = DateTime.Seconds(20),
			onTriggered = function()
				OrderForestPatrol(DateTime.Seconds(3))
				SpawnPlayerCamera(ForestPatrolStart.Location, DateTime.Seconds(6), "camera")
			end
		},
		forestTeamReturnWarning =
		{
			cells = { ForestPatrolStart.Location },
			location = ForestPatrolStart.Location,
			type = "camera.paradrop",
			condition = function(actor)
				return Executioner.IsDead and actor.Type == "dog"
			end
		},
		forestTeamAtBridge =
		{
			cells = { VillageBridgeNortheast.Location },
			location = VillageBridgeNortheast.Location,
			type = "camera.small",
			condition = function(actor)
				return Executioner.IsDead and actor.Type == "dog"
			end
		}
	}

	Utils.Do(mainReveals, function(reveal)
		local triggered = false
		local isCorrect = reveal.condition or function(actor)
			return IsGuideOrAllies(actor)
		end

		Trigger.OnEnteredFootprint(reveal.cells, function(actor, id)
			if triggered or not isCorrect(actor) then
				return
			end
			triggered = true
			Trigger.RemoveFootprintTrigger(id)

			if reveal.location then
				SpawnPlayerCamera(reveal.location, reveal.duration, reveal.type)
			end

			if reveal.onTriggered then
				reveal.onTriggered()
			end
		end)
	end)
end

PrepareBlockers= function()
	local houseReached = false

	Trigger.OnEnteredProximityTrigger(BlockerReturnProximity.CenterPosition, WDist.FromCells(2), function(actor, id)
		if not (Executioner.IsDead and actor.Owner == Greece) then
			return
		end
		Trigger.RemoveProximityTrigger(id)
		BlockersToBridgePatrol()
	end)

	Trigger.OnEnteredProximityTrigger(GuideHouseReveal.CenterPosition, WDist.FromCells(2), function(actor, id)
		if BlockerTank.IsDead then
			Trigger.RemoveProximityTrigger(id)
			return
		end

		if not (Executioner.IsDead and actor == BlockerTank) then
			return
		end

		Trigger.RemoveProximityTrigger(id)
		houseReached = true
	end)

	Trigger.OnEnteredProximityTrigger(SouthRiver.CenterPosition, WDist.FromCells(3), function(actor, id)
		if BlockerTank.IsDead then
			Trigger.RemoveProximityTrigger(id)
			return
		end

		if not (houseReached and Executioner.IsDead and actor == BlockerTank) then
			return
		end

		Trigger.RemoveProximityTrigger(id)
		SpawnPlayerCamera(SouthRiver.Location, DateTime.Seconds(6), "camera.tiny")
		SpawnPlayerCamera(ForestCenter.Location, DateTime.Seconds(20))
	end)
end

PrepareReveals = function()
	PrepareMainReveals()

	Trigger.OnEnteredProximityTrigger(Prison.CenterPosition, WDist.FromCells(10), function(actor, id)
		if not (IsGuideOrAllies(actor)) then
			return
		end
		Trigger.RemoveProximityTrigger(id)
		SpawnPlayerCamera(PrisonReveal.Location, DateTime.Seconds(20))

		local delay = DateTime.Seconds(1)
		if actor.Type == TanyaType then
			delay = 5
		end
		Trigger.AfterDelay(delay, OrderGeneralRetreat)
	end)

	Trigger.OnKilled(SovietDemoTruck, function()
		if not SovietDemoTruck.IsIdle then
			return
		end
		SpawnPlayerCamera(SovietDemoTruck.Location, DateTime.Seconds(1), "camera.paradrop")
	end)

	local otherExplosions =
	{
		{
			actors = { SouthBeachPump1, SouthBeachPump2 },
			origin = BeachExplosionReveal.Location
		},
		{
			actors = { PrisonPump, PrisonBarrel1, PrisonBarrel2, PrisonBarrel3, PrisonBarrel4 },
			origin = PrisonPump.Location
		},
		{
			actors = { DemoPump1, DemoPump2, DemoPump3, DemoHouse },
			origin = DemoBarrel3.Location
		},
		{
			actors = { NorthBeachPump2 },
			origin = NorthBeachPump2.Location
		},
		{
			actors = { LakePump1, LakePump2 },
			origin = LakeExplosionReveal.Location
		},

	}

	Utils.Do(otherExplosions, function(group)
		PrepareExplosionReveal(group.actors, group.origin, DateTime.Seconds(1))
	end)
end

PrepareExplosionReveal = function(actors, origin, duration)
	local revealed = false

	Utils.Do(actors, function(actor)
		Trigger.OnDamaged(actor, function(_, attacker)
			if revealed or not (attacker.Type == "barl" or "brl3") then
				return
			end
			revealed = true
			SpawnPlayerCamera(origin, duration, "camera.small")
		end)
	end)
end

PrepareChurch = function()
	Trigger.OnKilled(Church, OnChurchKilled)
	Trigger.OnPassengerEntered(Church, CheckEscortObjective)

	Trigger.OnEnteredProximityTrigger(Church.CenterPosition, WDist.FromCells(3), function(actor)
		if Church.IsDead or not (IsHostage(actor) or IsGuide(actor)) then
			return
		end

		actor.Stop()
		actor.Move(ChurchRally.Location)
		if IsGuide(actor) then
			actor.Infiltrate(Church)
			return
		end
		actor.EnterTransport(Church)
	end)
end

FireSale = function(player)
	print("FireSale grabbing actors.")
	local buildings = Utils.Where(player.GetActors(), function(actor)
		return actor.HasProperty("StartBuildingRepairs")
	end)

	print("FireSale selling.")
	Utils.Do(buildings, function(building)
		building.Sell()
	end)

	print("FireSale setting removal trigger.")
	Trigger.OnAllRemovedFromWorld(buildings, function()
		Trigger.AfterDelay(5, function()
			print("FireSale ordering hunt.")
			GroupIdleHunt(player.GetGroundAttackers())
		end)
	end)
end

SignalAllies = function()
	Greece.MarkCompletedObjective(SignalReinforcements)
	SpawnFlare(TanyaDrop.Location, DateTime.Minutes(4))
	Trigger.AfterDelay(DateTime.Seconds(1), ReinforceAllies)
	if General.IsDead then
		OrderBadGuyHunters()
		return
	end
	Trigger.OnKilled(General, OrderBadGuyHunters)
end

GroupAttackMove = function(actors, location, closeEnough)
	Utils.Do(actors, function(actor)
		if actor.IsDead then
			return
		end
		actor.AttackMove(location, closeEnough or 0)
	end)
end

GroupIdleHunt = function(actors)
	Utils.Do(actors, IdleHunt)
end

-- Patrol along path. Pause at each location until others arrive.
-- At final location, call onFinished(actors) or loop and restart.
GroupTightPatrol = function(actors, path, looped, pauseTime, onFinished)
	pauseTime = pauseTime or 0
	local paused = false
	local goal = 1
	local arrived = { }
	local patrollers = Utils.Where(actors, IsAlive)
	for id = 1, #patrollers do
		Trigger.OnIdle(patrollers[id], function(actor)
			if paused then
				return
			end

			if not arrived[id] then
				actor.AttackMove(path[goal], 2)
				actor.CallFunc(function()
					arrived[id] = true
				end)
				return
			end

			if not AreAllDeadOrIdle(patrollers) then
				return
			end

			-- All live actors have arrived and are idle.
			paused = true
			Trigger.AfterDelay(pauseTime, function()
				paused = false
			end)

			arrived = { }
			local nextLocation, patrolFinished = NextPatrolLocation(goal, #path, looped)

			if patrolFinished then
				ClearTightPatrol(patrollers, onFinished)
				return
			end

			goal = nextLocation
		end)
	end
end

NextPatrolLocation = function(current, final, looped)
	if current < final then
		return current + 1, false
	end

	if looped then
		return 1, false
	end

	return current, true
end

ClearTightPatrol = function(actors, onFinished)
	Utils.Do(actors, function(actor)
		if actor.IsDead then
			return
		end

		Trigger.Clear(actor, "OnIdle")
	end)

	if not onFinished then
		return
	end

	Trigger.AfterDelay(1, function()
		onFinished(actors)
	end)
end

GroupHuntOnDamaged = function(actors, targetPlayer)
	local alerted = false
	Utils.Do(actors, function(actor)
		Trigger.OnDamaged(actor, function(_, attacker)
			if alerted or attacker.Type == "dtrk" or not (attacker.Owner == targetPlayer) then
				return
			end
			alerted = true

			Utils.Do(actors, function(hunter)
				if hunter.IsDead or not hunter.HasProperty("Hunt") then
					return
				end
				-- Patrolling groups will need to halt.
				hunter.Stop()
				hunter.Hunt()
			end)
		end)
	end)
end

OrderForestPatrol = function(delay)
	local path =
	{
		ForestNorthwest.Location,
		ForestSouthwest.Location,
		SouthRiver.Location,
		GuideHouseReveal.Location,
		ForestPatrolStart.Location,
		VillageBridgeNortheast.Location,
		VillageNortheast.Location,
		PrisonReveal.Location,
		BadGuyRally.Location
	}

	Trigger.AfterDelay(delay, function()
		GroupTightPatrol(ForestTeam, path, false)
	end)
end

BlockersToGuideHouse = function()
	local path =
	{
		ForestPatrolStart.Location,
		ForestNorthwest.Location,
		SouthRiver.Location,
		GuideHouseReveal.Location
	}
	GroupTightPatrol(BlockerTeam, path, false)
end

BlockersToBridgePatrol = function()
	local path =
	{
		SouthRiver.Location,
		ForestSouthwest.Location,
		ForestNorthwest.Location,
		ForestPatrolStart.Location,
		VillageBridgeNortheast.Location,
		ForestPatrolStart.Location,
		ForestNorthwest.Location,
		ForestSouthwest.Location
	}
	GroupTightPatrol(BlockerTeam, path, true)
end

GuideStart = function()
	local guide = Actor.Create("c1", false, { Owner = GoodGuy, Location = GuideHouse.Location, SubCell = 4, Facing = Angle.South } )

	Trigger.OnAddedToWorld(guide, function()
		GuideToForest(guide)
	end)

	Trigger.AfterDelay(15, function()
		guide.IsInWorld = true
	end)
end

GuideToForest = function(guide)
	guide.Move(GuideHouse.Location + CVec.New(0, 1))

	guide.CallFunc(function()
		Media.DisplayMessage(UserInterface.Translate("guide-thank-you"), guide.TooltipName)
	end)

	guide.Move(SouthRiver.Location)
	guide.Move(ForestSouthwest.Location)
	guide.Move(ForestCenter.Location)
end

GuideToHideout = function(guide)
	if IsGroupDead(ForestTeam) then
		-- If this team dies, the Guide will skip ahead to GuideToVillage.
		return
	end
	guide.CallFunc(function()
		Media.DisplayMessage(UserInterface.Translate("guide-patrol-coming"), guide.TooltipName)
	end)

	guide.Wait(DateTime.Seconds(2))

	guide.CallFunc(function()
		if IsGroupDead(ForestTeam) then
			return
		end
		Media.DisplayMessage(UserInterface.Translate("guide-come-this-way"), guide.TooltipName)
		guide.Move(ForestHideout.Location)
	end)
end

GuideToVillage = function(guide)
	guide = guide or GetGuide()
	if not guide then
		return
	end

	Media.PlaySoundNotification(Greece, "GuideOkay")
	Media.DisplayMessage(UserInterface.Translate("guide-safe-to-move"), guide.TooltipName)
	guide.Wait(DateTime.Seconds(1))

	local path =
	{
		ForestNorthwest.Location,
		VillageBridgeNortheast.Location,
		PrisonIntersection.Location,
	}
	guide.Patrol(path, false)

	guide.CallFunc(function()
		GuideToHostages(guide)
	end)
end

GuideToHostages = function(guide)
	if Executioner.IsDead or PrisonBarrel2.IsDead or PrisonBarrel3.IsDead then
		return
	end
	-- To compensate for the guards' better speed/range with minimal changes,
	-- the Guide is made untargetable until actors are in position (or dead).
	local ghost = guide.GrantCondition("untargetable")

	Trigger.OnEnteredProximityTrigger(PrisonBarrel3.CenterPosition, WDist.FromCells(2), function(actor, id)
		if PrisonBarrel2.IsDead or guide.IsDead then
			Trigger.RemoveProximityTrigger(id)
			return
		end

		if not (actor.Type == "e1" and guide.Location == GuideBarrelGoal.Location) then
			return
		end

		Trigger.RemoveProximityTrigger(id)
		guide.Stop()
		guide.Attack(PrisonBarrel2)
	end)

	guide.Move(GuideBarrelGoal.Location)
	local revoked = false
	local revokeTargets = Utils.Where( { Executioner, PrisonBarrel1, PrisonBarrel2, PrisonBarrel3, PrisonBarrel4 }, IsAlive)

	Trigger.OnAnyKilled(revokeTargets, function()
		if revoked or guide.IsDead then
			return
		end
		revoked = true
		guide.RevokeCondition(ghost)
	end)
end

OrderGeneralRetreat = function()
	if General.IsDead or not General.IsIdle then
		return
	end
	local reinforcementTimer = DateTime.Seconds(30)

	General.Move(BadGuyRally.Location)
	General.Move(GeneralRally.Location + CVec.New(0, 3))

	General.CallFunc(function()
		local camera = SpawnPlayerCamera(GeneralRally.Location, reinforcementTimer)

		Trigger.OnKilled(General, function()
			RemoveActor(camera)
		end)
	end)

	General.Move(GeneralRally.Location)
	General.CallFunc(function()
		Trigger.AfterDelay(reinforcementTimer, ReinforceBadGuy)
	end)
end

OrderGuideRifles = function()
	local rifles = { GuideRifleWest, GuideRifleEast }
	local offset = 0

	Utils.Do(rifles, function(rifle)
		Trigger.AfterDelay(offset, function()
			if rifle.IsDead or GuideHouse.IsDead then
				return
			end
			rifle.Attack(GuideHouse, true, true)
		end)
		offset = offset + 8
	end)
end

OrderBadGuyHunters = function()
	local blockers = Utils.Where(BlockerTeam, IsAlive)
	ClearTightPatrol(blockers, function(actors)
		GroupAttackMove(actors, WestRoadRally.Location, 2)
		GroupIdleHunt(actors)
	end)

	local others = { SovietDemoTruck, DemoFlamer1, DemoFlamer2, ForwardCliffGuard2 }
	Utils.Do(others, function(other)
		if other.IsDead then
			return
		end
		other.AttackMove(WestRoadRally.Location)
		IdleHunt(other)
	end)
end

AreAllDeadOrIdle = function(actors)
	return Utils.All(actors, function(actor)
		return (actor.IsIdle or actor.IsDead)
	end)
end

GetGuide = function()
	local guides = GoodGuy.GetActorsByType("c1")
	return guides[1]
end

IsAlive = function(actor)
	return not actor.IsDead
end

IsGroupDead = function(actors)
	return Utils.Any(actors, function(actor)
		return actor.IsDead
	end)
end

IsGuide = function(actor)
	return actor.Owner == GoodGuy
end

IsGuideOrAllies = function(actor)
	return actor.Owner == Greece or IsGuide(actor)
end

IsHostage = function(actor)
	return actor.Owner == England
end

SpawnPlayerCamera = function(location, duration, type, delay)
	duration = duration or DateTime.Seconds(6)
	type = type or "camera"
	return SpawnMiscActor(type, England, location, duration, delay)
end

SpawnFlare = function(location, duration, delay)
	return SpawnMiscActor("flare", England, location, duration, delay)
end

SpawnMiscActor = function(type, owner, location, duration, delay)
	local actor = Actor.Create(type, false, { Owner = owner, Location = location or CPos.New(0, 0) } )

	if delay then
		Trigger.AfterDelay(delay, function()
			actor.IsInWorld = true
		end)
	else
		actor.IsInWorld = true
	end

	if duration and duration > 0 then
		RemoveActor(actor, duration)
	end

	return actor
end

RemoveActor = function(actor, delay)
	Trigger.AfterDelay(delay or 0, function()
		if not (actor and actor.IsInWorld) then
			return
		end
		actor.Destroy()
	end)
end

SpawnBeaconUntil = function(owner, position, repeatInterval, showOnRadarPings, stopCondition)
	if stopCondition() then
		return
	end
	Beacon.New(owner, position, repeatInterval, showOnRadarPings)
	Trigger.AfterDelay(repeatInterval, function()
		SpawnBeaconUntil(owner, position, repeatInterval, showOnRadarPings, stopCondition)
	end)
end

OnAnyHostageKilled = function()
	Greece.MarkFailedObjective(SaveAllHostages)
	if Greece.GetObjectiveType(SaveAllHostages) == "Primary" then
		AlliedDefeat(SaveAllHostages)
		return
	end
	CheckEscortObjective()
end

OnHostagesKilled = function()
	Media.PlaySoundNotification(Greece, "AlertBleep")
	Media.DisplayMessage(UserInterface.Translate("all-hostages-killed"))
	AlliedDefeat(FreeTheHostages)
end

OnHostagesEscorted = function()
	Greece.MarkCompletedObjective(EscortTheHostages)
	Media.PlaySpeechNotification(Greece, "ObjectiveMet")

	Trigger.AfterDelay(DateTime.Seconds(2), function()
		Media.DisplayMessage(UserInterface.Translate("signal-reinforcements"))
		-- Beacon seems to have a clean loop at 22-tick intervals
		SpawnBeaconUntil(England, TanyaDrop.CenterPosition, 22 * 2, false, function()
			return Greece.IsObjectiveCompleted(SignalReinforcements)
		end)
	end)
end

OnChurchKilled = function()
	Media.PlaySoundNotification(Greece, "AlertBleep")
	Media.DisplayMessage(UserInterface.Translate("church-destroyed"))
	AlliedDefeat(EscortTheHostages)
end

OnGuideRiflesKilled = function()
	if GuideHouse.IsDead then
		return
	end
	GuideStart()
end

OnTanyaKilled = function(_, killer)
	CheckAlliedDestruction()

	if killer.Type == "v2rl" and IsAlive(killer) then
		SpawnPlayerCamera(killer.Location, DateTime.Minutes(1), "camera.tiny")
	end
end
