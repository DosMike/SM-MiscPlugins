/** Loosely based on https://forums.alliedmods.net/showthread.php?t=223141 */

#include <sourcemod>
#include <tf2>
#include <tf2_stocks>

#define PLUGIN_VERSION "22w18c"

public Plugin myinfo = {
	name = "[TF2] Auto-Ready",
	author = "reBane",
	description = "Auto ready for MvM",
	version = PLUGIN_VERSION,
	url = "N/A"
}

int g_minPlayers;
float g_minRatio;

//set from ForceAllReady to prevent unnecessary handling of calls
bool g_ignoreReadyCommand;

public void OnPluginStart() {
	//hey, version convar
	ConVar cver = CreateConVar("mvm_autoready_version", PLUGIN_VERSION, "Plugin version", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	cver.AddChangeHook(ConVar_OnVersionChanged);
	cver.SetString(PLUGIN_VERSION);
	delete cver;
	//create and load convar for min players
	ConVar cvar1 = CreateConVar("mvm_autoready_threshold", "2", "Minimum players required to ready in order to start", _, true, 1.0, true, 10.0);
	g_minPlayers = cvar1.IntValue;
	cvar1.AddChangeHook(ConVar_OnMinPlayersChanged);
	delete cvar1;
	//create and load convar for min ratio
	ConVar cvar2 = CreateConVar("mvm_autoready_percent", "0.6", "Ratio of players that must ready in order to start", _, true, 0.0, true, 1.0);
	g_minRatio = cvar2.FloatValue;
	cvar2.AddChangeHook(ConVar_OnMinRatioChanged);
	//we don't need the convars anymore, change handlers sill get called
	delete cvar2;
	//reg admin command to force start the round
	RegAdminCmd("sm_forceallready", Command_ReadyAll, ADMFLAG_CHEATS, "Force all players to ready and start the round", "autoready");
	//player command to toggle ready
	AddCommandListener(Command_PlayerReadystate, "tournament_player_readystate");
	//with auto ready we temporarily disable the listener until a new round starts
	HookEvent("teamplay_round_start", OnNextWave);
	HookEvent("mvm_wave_complete", OnNextWave);
	HookEvent("mvm_wave_failed", OnNextWave);
}
public void ConVar_OnVersionChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!StrEqual(newValue, PLUGIN_VERSION)) {
		convar.SetString(PLUGIN_VERSION);
	}
}
public void ConVar_OnMinPlayersChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_minPlayers = convar.IntValue;
}
public void ConVar_OnMinRatioChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_minRatio = convar.FloatValue;
}

public void OnNextWave(Event event, const char[] name, bool dontBroadcast) {
	g_ignoreReadyCommand = false;
}

// auto ready logic

//as command listener this is called before the actual command function
//command usage: tournament_player_readystate <0|1>
public Action Command_PlayerReadystate(int client, const char[] command, int argc) {
	//are we force-readying? silently ignore our listener
	if (g_ignoreReadyCommand) return Plugin_Continue;
	//check for invalid command calls
	if (!IsClientValid(client, .allowBots=false) || argc != 1) return Plugin_Continue;
	//check current game state - if we are not expecting a ready, we cancel
	if (!IsGameMvM() || IsWaveRunning()) {
		ReplyToCommand(client, "[SM] Readying is currently not possible");
		return Plugin_Handled;
	}
	
	//get player decision
	bool isReady;
	char buffer[4];
	GetCmdArg(1, buffer, sizeof(buffer));
	if (StrEqual(buffer,"1")) isReady = true;
	else if (!StrEqual(buffer,"0")) {
		ReplyToCommand(client, "Invalid argument. Usage: tournament_player_readystate <0|1>");
		return Plugin_Handled; //i don't want to let you pass garbo
	}
	
	//check for actual state change, IsReady will retrieve the value before this command call
	if (isReady==IsReady(client)) return Plugin_Continue;
	//count ready players
	int readyCount, playerCount;
	readyCount = GetReadyCount(playerCount);
	// "predict" value, again we listen before the actual command function
	if (isReady) {
		readyCount += 1;
	} else {
		readyCount -= 1;
	}
	//get percentage ready
	float readyRatio = playerCount == 0 ? 0.0 : float(readyCount)/float(playerCount);
	//fancy logging
	bool countCondition = readyCount >= g_minPlayers;
	bool ratioCondition = readyRatio >= g_minRatio;
	PrintToChatAll("\x01[\x07E7B2FFAutoReady\x01] %N is %s\x01 - %s%d/%d\x01 and %s%.0f%%/%.0f%%", 
			client,
			(isReady?"\x07f1c232ready":"\x07999999not ready"),
			(countCondition?"\x078fce00":"\x07f44336"),readyCount, g_minPlayers, 
			(ratioCondition?"\x078fce00":"\x07f44336"),readyRatio*100.0, g_minRatio*100.0);
	if (readyCount == playerCount) {
		//this is a vanilla pass, we don't need to force ready
		g_ignoreReadyCommand = true;
		LogAction(client, -1, "[AutoReady] Vanilla condition of 100%% ready superseded", readyCount, playerCount, readyRatio*100.0);
		PrintToChatAll("\x01[\x07E7B2FFAutoReady\x01] All Players Ready - Let's go!");
	} else if (countCondition && ratioCondition) {
		LogAction(client, -1, "[AutoReady] Player triggered autoReady with %d/%d players at %.2f%%", readyCount, playerCount, readyRatio*100.0);
		PrintToChatAll("\x01[\x07E7B2FFAutoReady\x01] Enough Players Ready - Let's go!");
		RequestFrame(ForceAllReady); //do this next frame since we still pass, i guess
	}
	return Plugin_Continue;
}

public Action Command_ReadyAll(int client, int args) {
	//check current game state - if we are not expecting a ready, we cancel
	if (!IsGameMvM() || IsWaveRunning() || g_ignoreReadyCommand) {
		ReplyToCommand(client, "[SM] Readying is currently not possible");
	} else {
		ShowActivity2(client, "[SM] ", "%N forced the round to start", client);
		ForceAllReady();
	}
	return Plugin_Handled;
}


// utility functions

int GetReadyCount(int &total=0) {
	int redReady;
	for (int client=1; client<=MaxClients; client+=1) {
		if (IsClientValid(client, .allowBots=false) && TF2_GetClientTeam(client)==TFTeam_Red) {
			total+=1;
			if (IsReady(client)) redReady += 1;
		}
	}
	return redReady;
}
void ForceAllReady() {
	g_ignoreReadyCommand = true;
	for (int client=1; client<=MaxClients; client+=1) {
		if (IsClientValid(client, .allowBots=false) && TF2_GetClientTeam(client)==TFTeam_Red) {
			ForceReady(client);
		}
	}
	//g_ignoreReadyCommand is reset with game events
}

bool IsClientValid(int client, bool allowBots=true) {
	return (1<=client<=MaxClients) && IsClientInGame(client) && (allowBots || !IsFakeClient(client));
}
bool IsReady(int client) {
	return GameRules_GetProp("m_bPlayerReady", 1, client) != 0;
}
void ForceReady(int client) {
	FakeClientCommand(client, "tournament_player_readystate 1");
}
bool IsGameMvM() {
	return GameRules_GetProp("m_bPlayingMannVsMachine") != 0;
}
bool IsWaveRunning() {
	//i'm sure there's a more elegant way of testing, but i'm lazy
	return GameRules_GetRoundState() == RoundState_RoundRunning && GameRules_GetProp("m_bInWaitingForPlayers", 1) == 0
}