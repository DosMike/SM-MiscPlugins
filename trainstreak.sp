#include <sourcemod>
#include <sdkhooks>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w08a"

public Plugin myinfo = {
	name = "[TF2] Train-Streak",
	author = "reBane",
	description = "Kill streek for environmental deaths through vehicles",
	version = PLUGIN_VERSION,
	url = "N/A"
}

int trainStreak;

public void OnPluginStart() {
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
}

public void OnMapStart() {
	trainStreak = 0; //reset on map change
}

public Action OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int damagebits = event.GetInt("damagebits");
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	
	if ((damagebits & DMG_VEHICLE) && !attacker && victim) {
		event.SetInt("kill_streak_wep", ++trainStreak);
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

