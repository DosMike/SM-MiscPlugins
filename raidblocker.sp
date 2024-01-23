#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#include <sourcebanspp>
#include <playerbits>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "24w03a"

public Plugin myinfo = {
	name = "[TF2] RaidBlocker",
	author = "reBane",
	description = "", // make a @target for clients that are probably part of a bot raid
	version = PLUGIN_VERSION,
	url = "N/A"
}

//time to remember votes for
#define VOTE_MEMORY_TIME 120.0

//if defined, will automatically ban raids detected on the following conditions:
//#define VOTE_AUTOBAN
//how many votes / time to call, for triggering
#define VOTE_TRIGGER_COUNT_USER 5
//how many votes / time globally to call for triggering
#define VOTE_TRIGGER_COUNT_GLOBAL 10
//ban all clients with a vote count (within time) above this
#define VOTE_BAN_CALLCOUNT 10
//... and that joined withing this time from each other
#define VOTE_BAN_JOINTIME 5.0

//ban all clients with a vote count (within time) above this
#define VOTE_TARGET_CALLCOUNT 10
//... and that joined withing this time from each other
#define VOTE_TARGET_JOINTIME 5.0


StringMap g_votebin;
ArrayList g_globalbin;
Action ThinkVoteBins(Handle timer) {
	float now = GetGameTime();

	StringMapSnapshot snap = g_votebin.Snapshot();
	char steamid[MAX_AUTHID_LENGTH];
	for (int i=snap.Length-1; i>=0; i--) {
		snap.GetKey(i, steamid, sizeof(steamid));
		ArrayList votes;
		if (!g_votebin.GetValue(steamid, votes)) continue;
		for (int x=votes.Length-1; x>=0; x--) {
			float time = votes.Get(x);
			if (now-time >= VOTE_MEMORY_TIME) votes.Erase(x);
		}
		if (votes.Length == 0) {
			g_votebin.Remove(steamid);
		}
	}
	delete snap;

	for (int x=g_globalbin.Length-1; x>=0; x--) {
		float time = g_globalbin.Get(x);
		if (now-time >= VOTE_MEMORY_TIME) g_globalbin.Erase(x);
	}

	return Plugin_Continue;
}

public void OnPluginStart()
{
	AddCommandListener(gccallvote, "callvote");
	AddCommandListener(smvotekick, "sm_votekick");
	AddMultiTargetFilter("@botraid", TargetBotRaid, "Bot Raid", false);

	CreateTimer(1.0, ThinkVoteBins, _, TIMER_REPEAT);
	g_globalbin = new ArrayList();
	g_votebin = new StringMap();
}


public Action gccallvote(int client, const char[] cmd, int argc)
{
	//callvote signature:
	//  - callvote : show menu
	//  - callvote type detail
	//    types: RestartGame, Kick, ChangeLevel, NextLevel, ExtendLevel, ScrambleTeams, ChangeMission, Eternaween, TeamAutoBalance, ClassLimits, PauseGame
	//  callvote Kick <userid>

	if (argc < 2)
		return Plugin_Continue;
	
	char typestring[16];
	GetCmdArg(1, typestring, sizeof(typestring));
	
	if (!!strcmp(typestring, "kick", false))
		return Plugin_Continue;
	
	char detailstring[128];
	GetCmdArg(2, detailstring, sizeof(detailstring));

	int userid = StringToInt(detailstring);
	int target = GetClientOfUserId(userid);
	if (target < 1)
		return Plugin_Continue;
	
	RegisterVoteKick(client, target);
	
	return Plugin_Continue;
}

public Action smvotekick(int client, const char[] cmd, int argc)
{
	//sm_votekick signature:
	//  - sm_votekick <target> [reason]

	char targetstring[128];
	GetCmdArg(1, targetstring, sizeof(targetstring));

	int targets[MAXPLAYERS];
	char targetname[32];
	bool tn_is_ml;
	int count = ProcessTargetString(targetstring, client, targets, sizeof(targets), COMMAND_FILTER_NO_MULTI, targetname, sizeof(targetname), tn_is_ml);
	if (count < 1)
		return Plugin_Continue;
	
	RegisterVoteKick(client, targets[0]);

	return Plugin_Continue;
}

void RegisterVoteKick(int caller, int target)
{
	char steamid[MAX_AUTHID_LENGTH];
	if (!GetClientAuthId(caller, AuthId_Steam2, steamid, sizeof(steamid))) return;

	ArrayList votes;
	if (!g_votebin.GetValue(steamid, votes)) {
		votes = new ArrayList();
		g_votebin.SetValue(steamid, votes);
	}
	votes.Push(GetGameTime());
	g_globalbin.Push(GetGameTime());
	
#if defined VOTE_AUTOBAN
	if (votes.Length >= VOTE_TRIGGER_COUNT_USER && g_globalbin.Length >= VOTE_TRIGGER_COUNT_GLOBAL) {
		//ShowActivity(caller, "%L Triggered Raid Ban", caller);
		BanRaid(GetClientTime(caller));
	}
#endif
}

#if defined VOTE_AUTOBAN
void BanRaid(float playtime) {
	char steamid[MAX_AUTHID_LENGTH];

	for (int client=1; client<=MaxClients; client++) {
		if (!IsClientInGame(client) || IsFakeClient(client) || IsClientSourceTV(client) || IsClientReplay(client) || !IsClientAuthorized(client)) continue;
		if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid))) continue;

		ArrayList times;
		if (!g_votebin.GetValue(steamid, times)) continue;

		if (times.Length >= VOTE_BAN_CALLCOUNT && FloatAbs(GetClientTime(client)-playtime) <= VOTE_BAN_JOINTIME) {
			SBPP_BanPlayer(0, client, 0, "[Automated] Part of Raid");
			g_votebin.Remove(steamid);
		}
	}
}
#endif

bool TargetBotRaid(const char[] pattern, ArrayList clients, int client) {
	char steamid[MAX_AUTHID_LENGTH];
	PlayerBits player, equitime;
	ArrayList votes;

	for (int target=1; target<=MaxClients; target++) {
		if (target==client || !IsClientInGame(target) || IsFakeClient(target) || IsClientSourceTV(target) || IsClientReplay(target) || !IsClientAuthorized(target)) continue;
		if (!GetClientAuthId(target, AuthId_Steam2, steamid, sizeof(steamid))) continue;
		
		// for ever plyer that spammed votes get all players that joind roughly at the same time.
		// if there was at least one other player joining at the same time, add them all/both to the total set of players
		if (!g_votebin.GetValue(steamid, votes)) continue;
		if (votes.Length >= VOTE_TARGET_CALLCOUNT) {
			equitime.XorBits(equitime); // clear
			float playertime = GetClientTime(target);
			for (int other=1; other<=MaxClients; other++) {
				if (other==target || !IsClientInGame(other) || IsFakeClient(other) || IsClientSourceTV(other) || IsClientReplay(other) || !IsClientAuthorized(other)) continue;
				if (FloatAbs(GetClientTime(client)-playertime) <= VOTE_BAN_JOINTIME) {
					equitime.Or(other);
				}
			}
			if (equitime.Any()) {
				equitime.Or(target);
				player.OrBits(equitime);
			}
		}
		player.ToArrayList(clients);
	}

	return true;
}
