#region Copyright & License Information
/*
 * Copyright (c) The OpenRA Developers and Contributors
 * This file is part of OpenRA, which is free software. It is made
 * available to you under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version 3 of
 * the License, or (at your option) any later version. For more
 * information, see COPYING.
 */
#endregion

using System.Linq;
using OpenRA.Server;
using S = OpenRA.Server.Server;

namespace OpenRA.Mods.Common.Server
{
	public class PlayerPinger : ServerTrait, ITick
	{
		[FluentReference]
		const string PlayerDropped = "notification-player-dropped";

		[FluentReference("player")]
		const string ConnectionProblems = "notification-connection-problems";

		[FluentReference("player")]
		const string Timeout = "notification-timeout-dropped";

		[FluentReference("player", "timeout")]
		const string TimeoutIn = "notification-timeout-dropped-in";

		const int PingInterval = 5000; // Ping every 5 seconds
		const int ConnReportInterval = 20000; // Report every 20 seconds
		const int ConnTimeout = 60000; // Drop unresponsive clients after 60 seconds

		long lastPing = 0;
		long lastConnReport = 0;
		bool isInitialPing = true;

		public void Tick(S server)
		{
			if ((Game.RunTime - lastPing > PingInterval) || isInitialPing)
			{
				isInitialPing = false;
				lastPing = Game.RunTime;

				// Ignore client timeout in singleplayer games to make debugging easier
				var nonBotClientCount = 0;
				lock (server.LobbyInfo)
					nonBotClientCount = server.LobbyInfo.NonBotClients.Count();

				if (nonBotClientCount >= 2 || server.Type == ServerType.Dedicated)
				{
					foreach (var c in server.Conns.ToList())
					{
						if (!c.Validated)
							continue;

						var client = server.GetClient(c);
						if (client == null)
						{
							server.DropClient(c);
							server.SendFluentMessage(PlayerDropped);
							continue;
						}

						if (c.TimeSinceLastResponse < ConnTimeout)
						{
							if (!c.TimeoutMessageShown && c.TimeSinceLastResponse > PingInterval * 2)
							{
								server.SendFluentMessage(ConnectionProblems, "player", client.Name);
								c.TimeoutMessageShown = true;
							}
						}
						else
						{
							server.SendFluentMessage(Timeout, "player", client.Name);
							server.DropClient(c);
						}
					}

					if (Game.RunTime - lastConnReport > ConnReportInterval)
					{
						lastConnReport = Game.RunTime;

						var timeouts = server.Conns
							.Where(c => c.Validated && c.TimeSinceLastResponse > ConnReportInterval && c.TimeSinceLastResponse < ConnTimeout)
							.OrderBy(c => c.TimeSinceLastResponse);

						foreach (var c in timeouts)
						{
							var client = server.GetClient(c);
							if (client != null)
							{
								var timeout = (ConnTimeout - c.TimeSinceLastResponse) / 1000;
								server.SendFluentMessage(TimeoutIn, "player", client.Name, "timeout", timeout);
							}
						}
					}
				}
			}
		}
	}
}
