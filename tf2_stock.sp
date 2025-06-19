#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <tf2utils>
#include <tf_econ_data>
#include <tf2dropweapon>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "24w02a"

#define VOTE_MIN_PLAYERS 5
#define VOTE_MIN_PERCENT 50.0

public Plugin myinfo = {
	name = "[TF2] Stock",
	author = "reBane",
	description = "Play a game of stock TF2",
	version = PLUGIN_VERSION,
	url = "N/A"
}

bool g_forcedToStock[MAXPLAYERS+1];
float g_lastReminder[MAXPLAYERS+1];

bool g_voteForStock[MAXPLAYERS+1];

Handle g_updateTimers[MAXPLAYERS+1] = {INVALID_HANDLE, ...};

public void OnPluginStart() {
	LoadTranslations("common.phrases");

	RegAdminCmd("sm_forcestock", Cmd_ForceStock, ADMFLAG_SLAY, "Usage: <#uid|name> [0/1] - Force one or more players into stock, or lift the restriction");
	RegAdminCmd("sm_removeslot", Cmd_Test, ADMFLAG_SLAY, "Usage: <#uid|name> [0/1] - Force one or more players into stock, or lift the restriction");
	RegConsoleCmd("sm_votestock", Cmd_VoteStock, "Vote to play this map with stock weapons. Resets on map change");

	HookEvent("post_inventory_application", OnClientPostInventoryApplication);
}

public void OnClientConnected(int client) {
	g_forcedToStock[client] = g_forcedToStock[0];
}

public void OnClientDisconnect(int client) {
	g_forcedToStock[client] = false;
	g_lastReminder[client] = 0.0;
	g_voteForStock[client] = false;
	UpdateVote(client,false);
	if (g_updateTimers[client] != INVALID_HANDLE) {
		KillTimer(g_updateTimers[client]);
		g_updateTimers[client] = INVALID_HANDLE;
	}
}

public void OnMapEnd() {
	for (int i=0; i<=MAXPLAYERS; i++) {
		g_forcedToStock[i] = false;
		g_voteForStock[i] = false;
	}
}

public Action Cmd_ForceStock(int client, int args) {
	if (args < 1) {
		ReplyToCommand(client, "Usage: <#uid|name> [0/1]");
		return Plugin_Handled;
	}
	char buffer[128];
	
	GetCmdArg(1, buffer, sizeof(buffer));
	int targets[MAXPLAYERS];
	char targetname[128];
	bool tn_is_ml;
	int count = ProcessTargetString( buffer, client, targets, sizeof(targets), 0, targetname, sizeof(targetname), tn_is_ml );
	if (count <= 0) {
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}
	if (tn_is_ml) {
		Format(targetname, sizeof(targetname), "%T", targetname, client);
	}

	int force=-1;
	if (args > 1) {
		if (!GetCmdArgIntEx(2,force)) {
			ReplyToCommand(client, "Arg 2 should be numeric, non-zero to force stock");
			return Plugin_Handled;
		}
		force = force!=0;
	}

	for (int i=0; i<count; i++) {
		int target = targets[i];
		if (force==-1) g_forcedToStock[target] = !g_forcedToStock[target];
		else g_forcedToStock[target] = force!=0;
		
		if (IsClientInGame(target) && GetClientTeam(target)>1) {
			if (IsPlayerAlive(target)) {
				TF2_RespawnPlayer(target);
				TF2_RegeneratePlayer(target);
			}

			if (g_forcedToStock[target]) {
				PrintHintText(target, "[SM] You are now forced to stock weapons");
			} else {
				PrintHintText(target, "[SM] Stock restriction was lifted");
			}
		}
	}
	char action_string[16];
	if (force == -1) strcopy(action_string, sizeof(action_string), "toggled");
	else if (force == 0) strcopy(action_string, sizeof(action_string), "removed");
	else strcopy(action_string, sizeof(action_string), "forced");
	ShowActivity(client, "Stock weapons %s for %s", action_string, targetname);
	ReplyToCommand(client, "[SM] You %s stock weapons for %s", action_string, targetname);
	
	return Plugin_Handled;
}

public Action Cmd_Test(int client, int args) {
	int slot = GetCmdArgInt(1);
	int weapon = GetPlayerWeaponSlot(client, slot);
	int wslot = -1;
	if (weapon != INVALID_ENT_REFERENCE) wslot = TF2Util_GetWeaponSlot(weapon);
	ReplyToCommand(client, "Slot %i on WSlot %i", slot, wslot);
	return Plugin_Handled;
}

public Action Cmd_VoteStock(int client, int args) {
	if (client == 0) {
		ReplyToCommand(client, "[SM] Client command");
		return Plugin_Handled;
	}
	if (g_voteForStock[0]) {
		ReplyToCommand(client, "[SM] The vote has already passed this map");
		return Plugin_Handled;
	}

	UpdateVote(client);

	return Plugin_Handled;
}

void UpdateVote(int client, bool yes=true) {
	int ingame;
	for (int i=1; i<=MaxClients; i++) {
		if (IsClientInGame(i) && IsClientAuthorized(i) && GetClientTeam(i)>=1) ingame++;
	}
	if (ingame < VOTE_MIN_PLAYERS) {
		if (yes) ReplyToCommand(client, "[SM] Not enough players ingame (%i/%i)", ingame, VOTE_MIN_PLAYERS);
		return;
	}

	bool notify = yes && !g_forcedToStock[client];
	g_forcedToStock[client] = yes;
	//count votes
	int votes;
	for (int i=1; i<=MaxClients; i++) {
		if (g_forcedToStock[i]) votes++;
	}
	//calculate stuff
	float percentage = votes * 100.0 / ingame;
	int required_percent = RoundToCeil((VOTE_MIN_PERCENT-percentage) / 100.0 * ingame);
	int required_plain = (VOTE_MIN_PLAYERS-votes);
	int required = required_percent < required_plain ? required_plain : required_percent;
	if (required < 0) required = 0;
	//respond
	if (notify) {
		PrintToChatAll("[SM] %N wants to play a game of stock TF2. Use /votestock to vote. (%i/%i and %.0f%%/%.0f%%, %i more required)", client, votes, VOTE_MIN_PLAYERS, percentage, VOTE_MIN_PERCENT, required);
	} else if (yes) {
		ReplyToCommand(client, "[SM] You've already voted for stock");
	}
	if (required > 0) return;
	PrintToChatAll("[SM] Stock Weapon Mode enabled by Vote!");
	g_voteForStock[0] = true;
	for (int i; i<=MAXPLAYERS; i++) {
		g_forcedToStock[i] = true;
	}
	for (int i=1; i<=MaxClients; i++) {
		if (IsClientInGame(i) && IsPlayerAlive(i)) {
			TF2_RespawnPlayer(i);
			TF2_RegeneratePlayer(i);
		}
	}
}

void OnClientPostInventoryApplication(Event event, const char[] name, bool dontBroadcast) {
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!client || !isForcedToStock(client)) return;
	if (g_updateTimers[client] != INVALID_HANDLE)
		KillTimer(g_updateTimers[client]);
	g_updateTimers[client] = CreateTimer(0.1, UpdateWeaponsTimer, userid, TIMER_FLAG_NO_MAPCHANGE);
}

Action UpdateWeaponsTimer(Handle timer, any data) {
	int client = GetClientOfUserId(data);
	if (client) {
		g_updateTimers[client] = INVALID_HANDLE;
		UpdateWeapons(client);
	}
	return Plugin_Stop;
}

void UpdateWeapons(int client) {
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client)) return;

	TF2_RemoveAllWeapons(client);
	TFClassType class = TF2_GetPlayerClass(client);
	int max = (class == TFClass_Engineer || class == TFClass_Spy) ? 6 : 3;
	for (int slot; slot < max; slot++) {
		TF2DW_GiveWeaponForLoadoutSlot(client, slot, true);
	}
	//notify about this being forced to stock
	if (!IsFakeClient(client) && GetClientTime(client)-g_lastReminder[client] < 5.0) {
		g_lastReminder[client] = GetClientTime(client);
		PrintHintText(client, "You are restricted to stock weapons");
	}
}

// void GiveStockInSlot(int client, int slot) {
// 	int weapon = GetPlayerWeaponSlot(client, slot);
// 	if (weapon == INVALID_ENT_REFERENCE) return;
// 	if (!isForcedToStock(client)) return;
// 	//check if weapon is stock
// 	int itemdef = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
// 	if (itemdef >= 0 && !isWeaponStock(itemdef)) {
// 		TF2_RemoveWeaponSlot(client, slot);
// 		int loadoutslot = TF2Econ_GetItemLoadoutSlot(itemdef, TF2_GetPlayerClass(client));
// 		if (loadoutslot>=0) TF2DW_GiveWeaponForLoadoutSlot(client, loadoutslot, true);

// 		//notify about this being forced to stock
// 		if (!IsFakeClient(client) && GetClientTime(client)-g_lastReminder[client] < 5.0) {
// 			g_lastReminder[client] = GetClientTime(client);
// 			PrintHintText(client, "You are restricted to stock weapons");
// 		}
// 	}
// }

public Action TF2DW_OnClientPickupWeapon(int client, int droppedWeapon) {
	//prevent picking up non-stocks
	int itemdef = GetEntPropEnt(droppedWeapon, Prop_Send, "m_iItemDefinitionIndex");
	return (isForcedToStock(client) && !isWeaponStock(itemdef)) ? Plugin_Stop: Plugin_Continue;
}

public void TF2DW_OnClientDropWeaponPost(int client, int droppedWeapon) {
	//prevent littering non-stocks when forced out of them
	int itemdef = GetEntPropEnt(droppedWeapon, Prop_Send, "m_iItemDefinitionIndex");
	if (isForcedToStock(client) && !isWeaponStock(itemdef))
		AcceptEntityInput(droppedWeapon, "Kill");
}

bool isForcedToStock(int client) {
	return g_forcedToStock[client];// && !CheckCommandAccess(client, "ignorestock", ADMFLAG_CHEATS);
}

int findWeaponSlot(int client, int weapon) {
	for (int i; i < 6; i++) {
		if (GetPlayerWeaponSlot(client, i) == weapon) return i;
	}
	return -1;
}

bool isWeaponStock(int itemdef) {
	switch(itemdef) {
		//normal
		case 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,735:
			return true;
		//strange/renamed
		case 108,190,191,192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,209,210,211,212,736,737:
			return true;
		//not stock
		default: 
			return false;
	}
}
