#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>

#include <tf2utils>
#include <tf2attributes>

#pragma newdecls required
#pragma semicolon 1

#define VERSION        "25w45a"

#define TRI_IGNORE 0
#define TRI_REQUIRE 1
#define TRI_FILTER -1

public Plugin myinfo = {
	name = "[TF2] Additional Settings",
	author = "reBane",
	description = "More settings, in cvar and /admin",
	version = VERSION,
	url = ""
};

//boilerplate start
void LoadAndHookConVar(ConVar cvar, ConVarChanged changecb) {
	//manually trigger the change handler after loading the config, as that's not
	// considered a change in itself (just restoring).
	char value[128];
	cvar.GetString(value, sizeof(value));
	Call_StartFunction(INVALID_HANDLE, changecb);
	Call_PushCell(cvar);
	Call_PushString("");
	Call_PushString(value);
	Call_Finish();
	//hook for further changes
	cvar.AddChangeHook(changecb);
}
public void ConVarLocked(ConVar convar, const char[] oldValue, const char[] newValue) {
	char value[64];
	convar.GetDefault(value, sizeof(value));
	if (!StrEqual(value, newValue))
		convar.SetString(value);
}
public void ConVarVersionLocked(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!StrEqual(VERSION, newValue))
		convar.SetString(VERSION);
}
//boilerplate end

enum OptionState {
	STATE_UNCHANGED = 0,
	STATE_ENABLED = 1,
	STATE_DISABLED = 2
}
bool GetOptionState(OptionState optionValue, bool defaultValue) {
	switch(optionValue) {
		case STATE_ENABLED: { return true; }
		case STATE_DISABLED: { return false; }
		default: { return defaultValue; }
	}
}

OptionState sBackstabs = STATE_UNCHANGED;
#define GET_BACKSTABS GetOptionState(sBackstabs, true)
OptionState sInstagib = STATE_UNCHANGED;
#define GET_INSTAGIB GetOptionState(sInstagib, false)
OptionState sSentryguns = STATE_UNCHANGED;
#define GET_SENTRYGUNS GetOptionState(sSentryguns, false)

//convars and settup begin
public void OnPluginStart() {
	ConVar cvBackstabs = CreateConVar( "tf_backstabs", "1", "Set if spies can backstab. 1 allow, 0 disallow", _, true, 0.0, true, 1.0 );
	ConVar cvSentryguns = CreateConVar( "tf_disable_sentryguns", "0", "Disable sentryguns for engineers. 1 disable, 0 enable", _, true, 0.0, true, 1.0 );
	ConVar cvInstagib = CreateConVar( "mp_instagib", "0", "Enable insta-gib. 1 enable, 0 disable", _, true, 0.0, true, 1.0 );
	AutoExecConfig();
	LoadAndHookConVar(cvBackstabs, OnConVarChanged_Backstabs);
	LoadAndHookConVar(cvInstagib, OnConVarChanged_Instagib);
	LoadAndHookConVar(cvSentryguns, OnConVarChanged_Sentryguns);

	ConVar version = CreateConVar( "additionalsettings_version", VERSION, "Additional Settings Version", FCVAR_NOTIFY|FCVAR_DONTRECORD );
	LoadAndHookConVar(version, ConVarVersionLocked);
	delete version;

	for (int client=1; client <= MaxClients; client++) {
		if (!IsValidClient(client)) continue;
		HookClient(client);
	}

    AddCommandListener(OnBuildCommand, "build");
}

public void OnConVarChanged_Backstabs(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (StrEqual(newValue, "1")) sBackstabs = STATE_ENABLED;
	else if (StrEqual(newValue, "0")) sBackstabs = STATE_DISABLED;
	else sBackstabs = STATE_UNCHANGED;
	PrintToChatAll("[SM] Backstabs are now %s", GET_BACKSTABS ? "On" : "Off");
}
public void OnConVarChanged_Instagib(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (StrEqual(newValue, "1")) sInstagib = STATE_ENABLED;
	else if (StrEqual(newValue, "0")) sInstagib = STATE_DISABLED;
	else sInstagib = STATE_UNCHANGED;
	PrintToChatAll("[SM] Instagib is now %s", GET_INSTAGIB ? "On" : "Off");
}
public void OnConVarChanged_Sentryguns(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (StrEqual(newValue, "1")) sSentryguns = STATE_DISABLED;
	else if (StrEqual(newValue, "0")) sSentryguns = STATE_ENABLED;
	else sSentryguns = STATE_UNCHANGED;
	PrintToChatAll("[SM] Sentryguns are now %s", GET_SENTRYGUNS ? "Enabled" : "Disabled");
}

#include <sourcemod>
#include <tf2_stocks>

#define TF_OBJECT_DISPENSER 0
#define TF_OBJECT_SENTRY 2

public Action OnBuildCommand(int client, const char[] command, int argc)
{
	if (GET_SENTRYGUNS) {
		return Plugin_Continue;
	}

    if (IsClientInGame(client) && argc && TF2_GetPlayerClass(client) == TFClass_Engineer)
    {
        char arg1[11];
        GetCmdArg(1, arg1, sizeof(arg1));
        int building = StringToInt(arg1);
        if (building == TF_OBJECT_SENTRY) {
			PrintToChat(client, "[SM] Sentryguns are disabled");
            return Plugin_Handled;
		}
    }

    return Plugin_Continue;
}
//convars and settup end

//function implementation begin
bool IsValidClient(int client, bool requireIngame=true, bool allowBots=true, bool allowRecorders=false) {
	return (0 < client <= MaxClients)
	&&	(!requireIngame || IsClientInGame(client))
	&&	(allowBots || !IsFakeClient(client))
	&&	(allowRecorders || (!IsClientSourceTV(client) || IsClientReplay(client)))
	;
}

public void OnEntityCreated(int entity, const char[] classname) {
	if (IsValidClient(entity))
		HookClient(entity);
}

void HookClient(int client) {
	SDKHook(client, SDKHook_OnTakeDamageAlive, OnClientTakeDamage);
}

Action OnClientTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom) {
	bool changed = false;
	if (IsValidClient(attacker) && attacker != victim) {
		if (GET_INSTAGIB) {
			//simulated backstabs / super crits for instagib
			damage = GetClientHealth(victim) * 6.0;
			damagetype |= DMG_CRIT;
			changed = true;
		}
		
		//check if this is a backstab we need to block
		// it would be better to detour the spy knife and block the "can be backstabbed"-check, but i'm lazy
		else if (damagecustom == TF_CUSTOM_BACKSTAB && !GET_BACKSTABS) {
			damage = 40.0; //knife base damage
			damagetype &=~ DMG_CRIT;
			changed = true;
		}
		
	}
	return changed ? Plugin_Changed : Plugin_Continue;
}

//function implementation end

//utility functions begin
/**
 * @param boss - 1 to require boss bots, -1 to filter boss bots, 0 to ignore. use TRI_* for readability
 */
stock bool IsClientBot(int entity, int boss=TRI_IGNORE) {
	if (!IsValidClient(entity)) return false;
	bool isbot = !!GetEntProp(entity, Prop_Send, "m_bIsABot");
	bool isboss = !!GetEntProp(entity, Prop_Send, "m_bIsMiniBoss");
	return isbot && (!boss || isboss == (boss>0));
}
//utility functions end

