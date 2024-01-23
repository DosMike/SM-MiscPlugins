#include <sourcemod>
#include <sdkhooks>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w12a"

public Plugin myinfo = {
	name = "[TF2] Train-Streak",
	author = "reBane",
	description = "Kill streek for environmental deaths through vehicles",
	version = PLUGIN_VERSION,
	url = "N/A"
}

int trainStreak;
int sawStreak;
int crocStreak;

public void OnPluginStart() {
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);
}

public void OnMapStart() {
	trainStreak = 0;
	sawStreak = 0;
	crocStreak = 0;
}

public Action OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int damagebits = event.GetInt("damagebits");
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	
	if (!attacker && victim) {
		if ((damagebits & DMG_VEHICLE)) {
			event.SetInt("kill_streak_wep", ++trainStreak);
			return Plugin_Changed;
		} else if ((damagebits & DMG_NERVEGAS)) {
			event.SetInt("kill_streak_wep", ++sawStreak);
			return Plugin_Changed;
		} else if ((damagebits & DMG_CRUSH)) {
			event.SetInt("kill_streak_wep", ++crocStreak);
			return Plugin_Changed;
		// } else {
		// 	PrintToServer("DamageBits %08X", damagebits);
		}
	}
	return Plugin_Continue;
}

