--[[
   Copyright (c) The OpenRA Developers and Contributors
   This file is part of OpenRA, which is free software. It is made
   available to you under the terms of the GNU General Public License
   as published by the Free Software Foundation, either version 3 of
   the License, or (at your option) any later version. For more
   information, see COPYING.
]]

AlliedUnits =
{
	{ types = { "1tnk", "1tnk", "2tnk", "2tnk" }, point = StartRally1, delay = 0 },
	{ types = { "e1", "e1", "e1", "e3", "e3" }, point = StartRally2, delay = DateTime.Seconds(3) },
	{ types = { "e6", "e6", "thf" }, point = StartRally3, delay = DateTime.Seconds(7) },
}
ReinforceBaseUnits = { "1tnk", "1tnk", "2tnk", "arty", "arty" }
CivilianEvacuees = { "c2", "c3", "c5", "c6", "c8" }
USSROutpostFlameTurrets = { FlameTurret1, FlameTurret2 }
ExplosiveBarrels = { FlameTurretBarrel1, FlameTurretBarrel2 }
SuperTanks = { stnk1, stnk2, stnk3 }
SuperTankMoveWaypoints = { HospitalSuperTankPoint, AlliedBaseBottomRight, DemitriTriggerAreaCenter, DemitriLZ }
SuperTankMove = 1
SuperTankHuntWaypoints = { SuperTankHuntWaypoint1, SuperTankHuntWaypoint2, SuperTankHuntWaypoint3, SuperTankHuntWaypoint4 }
SuperTankHunt = 1
SuperTankHuntCounter = 1
ExtractionHeli = "tran"
ExtractionWaypoint = CPos.New(DemitriLZ.Location.X, 19)
ExtractionLZ = DemitriLZ.Location
BeachTrigger = { CPos.New(19, 44), CPos.New(20, 44), CPos.New(21, 44), CPos.New(22, 44), CPos.New(22, 45), CPos.New(23, 45), CPos.New(22, 44), CPos.New(24, 45), CPos.New(24, 46), CPos.New(24, 47), CPos.New(25, 47), CPos.New(25, 48) }
DemitriAreaTrigger = { CPos.New(32, 98), CPos.New(32, 99), CPos.New(33, 99), CPos.New(33, 100), CPos.New(33, 101), CPos.New(33, 102), CPos.New(32, 102), CPos.New(32, 103) }
HospitalAreaTrigger = { CPos.New(43, 41), CPos.New(44, 41), CPos.New(45, 41), CPos.New(46, 41), CPos.New(46, 42), CPos.New(46, 43), CPos.New(46, 44), CPos.New(46, 45), CPos.New(46, 46), CPos.New(45, 46), CPos.New(44, 46), CPos.New(43, 46) }
SuperTankDomeDiscovered = false

EvacuateCivilians = function()
	local evacuees = Reinforcements.Reinforce(England, CivilianEvacuees, { HospitalCivilianSpawnPoint.Location }, 0, function(a)
		a.Scatter()
	end)

	Trigger.OnAnyKilled(evacuees, function()
		Greece.MarkFailedObjective(RescueCivilians)
	end)
	Trigger.OnAllRemovedFromWorld(evacuees, function()
		Greece.MarkCompletedObjective(RescueCivilians)
	end)

	Utils.Do(evacuees, function(civ)
		Trigger.OnIdle(civ, function()
			if civ.Location == AlliedBaseEntryPoint.Location then
				civ.Destroy()
			else
				civ.Move(AlliedBaseEntryPoint.Location)
			end
		end)
	end)
end

SendSovietParadrop = function()
	local proxy = Actor.Create("powerproxy.paratroopers", false, { Owner = USSR })
	local angle = (SovietBadgerGoal.CenterPosition - SovietBadgerEntry.CenterPosition).Facing
	local plane = proxy.TargetParatroopers(SovietBadgerGoal.CenterPosition, angle)[1]
	proxy.Destroy()

	Trigger.OnPassengerExited(plane, function(_, passenger)
		IdleHunt(passenger)
	end)
end

OrderPenAttack = function(pen)
	if BeachLauncher.IsDead then
		return
	end

	local penWarhead = BeachLauncher.GrantCondition("using-percentage-warhead")

	Trigger.OnIdle(BeachLauncher, function()
		if pen.IsInWorld then
			BeachLauncher.Attack(pen)
			return
		end

		Trigger.ClearAll(BeachLauncher)
		BeachLauncher.Stance = "AttackAnything"
		BeachLauncher.RevokeCondition(penWarhead)
	end)
end

OrderSupplyTruckRetreat = function(trucks)
	local path = { SupplyTruckWaypoint1.Location, SupplyTruckWaypoint2.Location, SupplyTruckWaypoint3.Location }

	Utils.Do(trucks, function(truck)
		if truck.IsDead then
			return
		end

		truck.Move(path[1], 2)
		truck.Move(path[2], 2)

		Trigger.OnIdle(truck, function()
			if truck.Location == path[3] then
				Trigger.Clear(truck, "OnIdle")
				return
			end

			-- Include this truck in the later Super Tank explosion.
			truck.Owner = USSR
			truck.Move(path[3])
		end)
	end)
end

SpawnAndMoveAlliedBaseUnits = function()
	Media.PlaySpeechNotification(Greece, "ReinforcementsArrived")
	Reinforcements.Reinforce(Greece, ReinforceBaseUnits, { AlliedBaseEntryPoint.Location, AlliedBaseMovePoint.Location }, 18)
end

SetupAlliedBase = function()
	local alliedOutpost = Map.ActorsInBox(AlliedBaseTopLeft.CenterPosition, AlliedBaseBottomRight.CenterPosition,
		function(self) return self.Owner == Outpost end)

	Media.PlaySoundNotification(Greece, "BaseSetup")
	Utils.Do(alliedOutpost, function(building)
		building.Owner = Greece
	end)

	AlliedBaseHarv.Owner = Greece
	AlliedBaseHarv.FindResources()

	FindDemitri = AddPrimaryObjective(Greece, "find-demitri")
	InfiltrateRadarDome = AddPrimaryObjective(Greece, "reprogram-super-tanks")
	DefendOutpost = AddSecondaryObjective(Greece, "defend-outpost")
	Greece.MarkCompletedObjective(FindOutpost)

	-- Don't fail the Objective instantly
	Trigger.AfterDelay(DateTime.Seconds(1), function()

		-- The actor might have been destroyed/crushed in this one second delay
		local actors = Utils.Where(alliedOutpost, function(actor) return actor.IsInWorld end)
		Trigger.OnAllRemovedFromWorld(actors, function() Greece.MarkFailedObjective(DefendOutpost) end)
	end)

	Trigger.AfterDelay(DateTime.Minutes(1) + DateTime.Seconds(40), function()
		if not SuperTankDomeIsInfiltrated then
			SuperTankAttack = true
			Utils.Do(SuperTanks, function(tnk)
				if not tnk.IsDead then
					Trigger.ClearAll(tnk)
					Trigger.AfterDelay(0, function()
						Trigger.OnIdle(tnk, function()
							if SuperTankAttack then
								if tnk.Location == SuperTankMoveWaypoints[SuperTankMove].Location then
									SuperTankMove = SuperTankMove + 1
									if SuperTankMove == 5 then
										SuperTankAttack = false
									end
								else
									tnk.AttackMove(SuperTankMoveWaypoints[SuperTankMove].Location, 2)
								end
							end
						end)
					end)
				end
			end)
		end
	end)
end

SendAlliedUnits = function()
	AddObjectives()

	Camera.Position = StartEntryPoint.CenterPosition

	Media.PlaySpeechNotification(Greece, "ReinforcementsArrived")
	Utils.Do(AlliedUnits, function(table)
		Trigger.AfterDelay(table.delay, function()
			local rallyCell = table.point.Location
			local units = Reinforcements.Reinforce(Greece, table.types, { StartEntryPoint.Location, StartRally3.Location, rallyCell }, 18)

			Utils.Do(units, function(unit)
				if unit.Type == "e6" then
					Engineer = unit
					Trigger.OnKilled(unit, LandingPossible)
				elseif unit.Type == "thf" then
					Trigger.OnKilled(unit, function()
						Greece.MarkFailedObjective(StealMoney)
					end)
				end
			end)
		end)
	end)

	Trigger.AfterDelay(DateTime.Seconds(1), function() InitialUnitsArrived = true end)
end

LandingPossible = function()
	if not BeachReached and (USSRSpen.IsDead or Engineer.IsDead) and LstProduced < 1 then
		Greece.MarkFailedObjective(CrossRiver)
	end
end

SuperTankDomeInfiltrated = function()
	SuperTankAttack = true
	Utils.Do(SuperTanks, function(tnk)
		tnk.Owner = FriendlyMadTanks
		if not tnk.IsDead then
			tnk.GrantCondition("friendly")
			Trigger.ClearAll(tnk)
			tnk.Stop()
			if tnk.Location.Y > 61 then
				SuperTankHunt = 4
				SuperTankHuntCounter = -1
			end
			Trigger.AfterDelay(0, function()
				Trigger.OnIdle(tnk, function()
					if SuperTankAttack then
						if tnk.Location == SuperTankHuntWaypoints[SuperTankHunt].Location then
							SuperTankHunt = SuperTankHunt + SuperTankHuntCounter
							if SuperTankHunt == 0 or SuperTankHunt == 5 then
								SuperTankAttack = false
							end
						else
							tnk.AttackMove(SuperTankHuntWaypoints[SuperTankHunt].Location, 2)
						end
					else
						tnk.Hunt()
					end
				end)
			end)
		end
	end)

	Greece.MarkCompletedObjective(InfiltrateRadarDome)
	Trigger.AfterDelay(DateTime.Minutes(3), SuperTanksDestruction)
	Ticked = DateTime.Minutes(3)

	Trigger.AfterDelay(DateTime.Seconds(2), function()
		Media.PlaySpeechNotification(Greece, "ControlCenterDeactivated")

		Trigger.AfterDelay(DateTime.Seconds(4), function()
			Media.DisplayMessage(UserInterface.GetFluentMessage("super-tank-self-destruct-t-minus-3"))
			Media.PlaySpeechNotification(Greece, "WarningThreeMinutesRemaining")
		end)
	end)
end

SuperTanksDestruction = function()
	local southBaseSoviets = Utils.Where(USSR.GetActors(), function(self)
		return self.HasProperty("Health") and
		self.Location.Y > SupplyTruckWaypoint2.Location.Y and
		self.Location.X > SovietOrePoint.Location.X
	end)

	Utils.Do(southBaseSoviets, function(unit)
		unit.Kill("ExplosionDeath")
	end)

	Utils.Do(SuperTanks, function(tnk)
		if not tnk.IsDead then
			local camera = Actor.Create("camera", true, { Owner = Greece, Location = tnk.Location })
			Trigger.AfterDelay(DateTime.Seconds(3), camera.Destroy)

			Trigger.ClearAll(tnk)
			tnk.Kill("ExplosionDeath")
		end
	end)

	Greece.MarkCompletedObjective(DefendOutpost)
end

RevealSuperTankDome = function()
	if SuperTankDomeIsInfiltrated or SuperTankDomeDiscovered or SuperTankDome.IsDead then
		return
	end

	Media.PlaySpeechNotification(Greece, "SignalFlareEast")
	Actor.Create("flare", true, { Owner = England, Location = SuperTankDomeFlarePoint.Location })
end

CreateDemitri = function()
	local demitri = Actor.Create("demitri", true, { Owner = Greece, Location = DemitriChurchSpawnPoint.Location })
	demitri.Move(DemitriTriggerAreaCenter.Location)

	Media.PlaySpeechNotification(Greece, "TargetFreed")
	EvacuateDemitri = AddPrimaryObjective(Greece, "evacuate-demitri")
	Greece.MarkCompletedObjective(FindDemitri)

	local flarepos = CPos.New(DemitriLZ.Location.X, DemitriLZ.Location.Y - 1)
	local demitriLZFlare = Actor.Create("flare", true, { Owner = Greece, Location = flarepos })
	Trigger.AfterDelay(DateTime.Seconds(3), function() Media.PlaySpeechNotification(Greece, "SignalFlareNorth") end)

	local demitriChinook = Reinforcements.ReinforceWithTransport(Greece, ExtractionHeli, nil, { ExtractionWaypoint, ExtractionLZ })[1]

	Trigger.OnAnyKilled({ demitri, demitriChinook }, function()
		Greece.MarkFailedObjective(EvacuateDemitri)
	end)

	Trigger.OnRemovedFromWorld(demitriChinook, function()
		if not demitriChinook.IsDead then
			Media.PlaySpeechNotification(Greece, "TargetRescued")
			SendSovietParadrop()
			Trigger.AfterDelay(DateTime.Seconds(1), function() Greece.MarkCompletedObjective(EvacuateDemitri) end)
			Trigger.AfterDelay(DateTime.Seconds(3), SpawnAndMoveAlliedBaseUnits)
			Trigger.AfterDelay(DateTime.Seconds(7), RevealSuperTankDome)
		end
	end)
	Trigger.OnRemovedFromWorld(demitri, function()
		if not demitriChinook.IsDead and demitriChinook.HasPassengers then
			demitriChinook.Move(ExtractionWaypoint + CVec.New(0, -1))
			demitriChinook.Destroy()
			demitriLZFlare.Destroy()
		end
	end)
end

Ticked = -1
Tick = function()
	USSR.Resources = USSR.Resources - (0.01 * USSR.ResourceCapacity / 25)

	if InitialUnitsArrived then -- don't fail the mission straight at the beginning
		if not DemitriFound or not SuperTankDomeIsInfiltrated then
			if Greece.HasNoRequiredUnits() then
				Greece.MarkFailedObjective(EliminateSuperTanks)
			end
		end
	end

	if Ticked > 0 then
		if (Ticked % DateTime.Seconds(1)) == 0 then
			Timer = UserInterface.GetFluentMessage("super-tank-self-destruct-in", { ["time"] = Utils.FormatTime(Ticked) })
			UserInterface.SetMissionText(Timer, TimerColor)
		end
		Ticked = Ticked - 1
	elseif Ticked == 0 then
		FinishTimer()
		Ticked = Ticked - 1
	end
end

FinishTimer = function()
	for i = 0, 9, 1 do
		local c = TimerColor
		if i % 2 == 0 then
			c = HSLColor.White
		end

		Trigger.AfterDelay(DateTime.Seconds(i), function() UserInterface.SetMissionText(UserInterface.GetFluentMessage("super-tanks-destroyed"), c) end)
	end
	Trigger.AfterDelay(DateTime.Seconds(10), function() UserInterface.SetMissionText("") end)
end

SetupMission = function()
	TestCamera = Actor.Create("camera" ,true , { Owner = Greece, Location = ProvingGroundsCameraPoint.Location })
	Camera.Position = ProvingGroundsCameraPoint.CenterPosition
	TimerColor = Greece.Color

	Trigger.AfterDelay(DateTime.Seconds(12), function()
		Media.PlaySpeechNotification(Greece, "StartGame")
		Trigger.AfterDelay(DateTime.Seconds(2), SendAlliedUnits)
	end)
end

InitPlayers = function()
	Greece = Player.GetPlayer("Greece")
	Neutral = Player.GetPlayer("Neutral")
	England = Player.GetPlayer("England")
	Outpost = Player.GetPlayer("Outpost")
	BadGuy = Player.GetPlayer("BadGuy")
	USSR = Player.GetPlayer("USSR")
	FriendlyMadTanks = Player.GetPlayer("FriendlyMadTanks")

	USSR.Cash = 2000
	Trigger.AfterDelay(0, function() BadGuy.Resources = BadGuy.ResourceCapacity * 0.75 end)
end

AddObjectives = function()
	InitObjectives(Greece)

	EliminateSuperTanks = AddPrimaryObjective(Greece, "eliminate-super-tanks")
	StealMoney = AddPrimaryObjective(Greece, "steal-money-outpost")
	CrossRiver = AddPrimaryObjective(Greece, "cross-river")
	FindOutpost = AddPrimaryObjective(Greece, "find-outpost-and-repair")
	RescueCivilians = AddSecondaryObjective(Greece, "evacuate-civilian-hospital")

	Trigger.OnPlayerWon(Greece, function()
		Media.DisplayMessage(UserInterface.GetFluentMessage("demitri-extracted-super-tanks-destroyed"))
	end)
end

InitTriggers = function()
	local badTrucks = BadGuy.GetActorsByType("badtruk")
	Trigger.OnAnyKilled(badTrucks, function()
		OrderSupplyTruckRetreat(badTrucks)
	end)

	Trigger.OnAllKilled(SuperTanks, function()
		Trigger.AfterDelay(DateTime.Seconds(3), function() Greece.MarkCompletedObjective(EliminateSuperTanks) end)
	end)

	Trigger.OnKilled(SuperTankDome, function()
		if not SuperTankDomeIsInfiltrated then
			Greece.MarkFailedObjective(InfiltrateRadarDome)
		end
	end)
	Trigger.OnInfiltrated(SuperTankDome, function()
		if not SuperTankDomeIsInfiltrated then
			SuperTankDomeIsInfiltrated = true
			SuperTankDomeInfiltrated()
		end
	end)
	Trigger.OnCapture(SuperTankDome, function()
		if not SuperTankDomeIsInfiltrated then
			SuperTankDomeIsInfiltrated = true
			SuperTankDomeInfiltrated()
		end
	end)
	Trigger.OnDiscovered(SuperTankDome, function(_, discoverer)
		SuperTankDomeDiscovered = SuperTankDomeDiscovered or discoverer == Greece
	end)

	Trigger.OnKilled(UkraineBarrel, function()
		if not UkraineBuilding.IsDead then UkraineBuilding.Kill() end
	end)

	for i = 1, 2 do
		Trigger.OnKilled(USSROutpostFlameTurrets[i], function()
			if not ExplosiveBarrels[i].IsDead then
				ExplosiveBarrels[i].Kill()
			end
		end)
	end

	Trigger.OnKilled(DemitriChurch, function(_, killer)
		if DemitriFound then
			return
		else
			Greece.MarkFailedObjective(FindDemitri)
		end

		if killer.Owner ~= Greece then
			Actor.Create("camera", true, { Owner = Greece, Location = DemitriChurchSpawnPoint.Location })
			Camera.Position = DemitriChurchSpawnPoint.CenterPosition
		end
	end)

	Trigger.OnKilled(Hospital, function()
		if not HospitalEvacuated then
			HospitalEvacuated = true
			Greece.MarkFailedObjective(RescueCivilians)
		end
	end)

	Trigger.OnInfiltrated(USSROutpostSilo, function()
		MoneyStolen = true
		Greece.MarkCompletedObjective(StealMoney)
		Trigger.AfterDelay(1, function()
			Greece.Cash = math.max(Greece.Cash, Actor.Cost("lst"))
		end)
	end)

	Trigger.OnKilledOrCaptured(USSROutpostSilo, function()
		if not MoneyStolen then
			Greece.MarkFailedObjective(StealMoney)
		end
	end)

	Trigger.OnEnteredFootprint(BeachTrigger, function(a, id)
		if not BeachReached and a.Owner == Greece and a.Type ~= "lst" then
			BeachReached = true
			Trigger.RemoveFootprintTrigger(id)
			Greece.MarkCompletedObjective(CrossRiver)
		end
	end)

	Trigger.OnPlayerDiscovered(Outpost, function(_, discoverer)
		if not OutpostReached and discoverer == Greece then
			OutpostReached = true
			SetupAlliedBase()
		end
	end)

	Trigger.OnEnteredFootprint(DemitriAreaTrigger, function(a, id)
		if not DemitriFound and a.Owner == Greece then
			DemitriFound = true
			Trigger.RemoveFootprintTrigger(id)
			CreateDemitri()
		end
	end)

	Trigger.OnEnteredFootprint(HospitalAreaTrigger, function(a, id)
		if not HospitalEvacuated and a.Owner == Greece then
			HospitalEvacuated = true
			Trigger.RemoveFootprintTrigger(id)
			EvacuateCivilians()
		end
	end)

	local tanksLeft = 0
	Trigger.OnExitedProximityTrigger(ProvingGroundsCameraPoint.CenterPosition, WDist.New(10 * 1024), function(a, id)
		if a.Type == "5tnk" then
			tanksLeft = tanksLeft + 1
			if tanksLeft == 3 then
				if TestCamera.IsInWorld then TestCamera.Destroy() end
				Trigger.RemoveProximityTrigger(id)
			end
		end
	end)

	LstProduced = 0
	Trigger.OnKilled(USSRSpen, LandingPossible)
	Trigger.OnSold(USSRSpen, LandingPossible)
	Trigger.OnCapture(USSRSpen, OrderPenAttack)
	Trigger.OnProduction(USSRSpen, function(self, produced)
		if produced.Type == "lst" then
			LstProduced = LstProduced + 1
			Trigger.OnKilled(produced, function()
				LstProduced = LstProduced - 1
				LandingPossible()
			end)
		end
	end)
end

WorldLoaded = function()
	InitPlayers()
	InitTriggers()
	SetupMission()
end
