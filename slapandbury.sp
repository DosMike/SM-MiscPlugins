#include <sourcemod>
#include <dbi>
#include <sdkhooks>
#include <sdktools>
#if SOURCEMOD_V_MAJOR == 1 && SOURCEMOD_V_MINOR < 11
#include <SetCollisionGroup> //is included in sourcemod with 1.11
#endif

#define PLUGIN_VERSION "22w24a"

public Plugin myinfo = {
	name = "Slap and Bury",
	author = "reBane",
	description = "Better Slap and Bury for admins",
	version = PLUGIN_VERSION,
	url = "N/A"
}

enum struct BuryData {
	bool IsBuried;
	bool PreGroundFlagged;
	MoveType PreMoveType;
	int PreCollisionGroup;
	int InEntityRef;
	float BuryDistance;
}
BuryData g_bury[MAXPLAYERS+1];
methodmap Player {
	public Player(int client) {
		return view_as<Player>( client );
	}
	property int Client {
		public get() { return view_as<int>( this ); }
	}
	property int UserID {
		public get() { return GetClientUserId( this.Client ); }
	}
	public bool IsValid(bool requireInGame=true, bool requireAlive=true) {
		return (1<=this.Client<=MaxClients) && 
			(!requireInGame || IsClientInGame(this.Client)) &&
			(!requireAlive || IsPlayerAlive(this.Client)) ;
	}
	public void Bury() {
		if (g_bury[this.Client].IsBuried) return;
		g_bury[this.Client].PreGroundFlagged = (GetEntityFlags(this.Client)&FL_ONGROUND)!=0;
		g_bury[this.Client].PreMoveType = GetEntityMoveType(this.Client);
		g_bury[this.Client].PreCollisionGroup = GetEntProp(this.Client, Prop_Send, "m_CollisionGroup");
		float buryPos[3];
		GetClientAbsOrigin(this.Client, buryPos);
		float preZ = buryPos[2];
		int buryParent = 0;//world
		//scan down for potential parrenting }:D
		float mins[3], maxs[3], end[3];
		GetClientMins(this.Client, mins);
		GetClientMaxs(this.Client, maxs);
		end = buryPos;
		end[2] -= 2048; //arbitrary "scan down"
		Handle hdlTrace = TR_TraceHullFilterEx(buryPos, end, mins, maxs, MASK_PLAYERSOLID, TRFilter_NoClients);
		if (TR_DidHit(hdlTrace)) {
			TR_GetEndPosition(buryPos, hdlTrace);
			buryParent = TR_GetEntityIndex(hdlTrace);
			g_bury[this.Client].InEntityRef = EntIndexToEntRef(buryParent);
		} else {
			g_bury[this.Client].InEntityRef = INVALID_ENT_REFERENCE;
		}
		delete hdlTrace;
		//actually bury them already
		buryPos[2] -= 30; //in floor
		SetEntityMoveType(this.Client, MOVETYPE_NONE);
		SetEntityCollisionGroup(this.Client, 0);
		float zeros[3];
		TeleportEntity(this.Client, buryPos, NULL_VECTOR, zeros);
		if (buryParent) {
			SetVariantString("!activator");
			AcceptEntityInput(this.Client, "SetParent", buryParent, -1, 0);
		}
		g_bury[this.Client].BuryDistance = preZ - buryPos[2];
		g_bury[this.Client].IsBuried = true;
		char soundName[40];
		Format(soundName, sizeof(soundName), "physics/body/body_medium_break%i.wav", GetRandomInt(2,4));
		EmitSoundToAll(soundName, this.Client);
	}
	public void Unbury(bool playSound=true) {
		if (!g_bury[this.Client].IsBuried) return;
		int inent = EntRefToEntIndex(g_bury[this.Client].InEntityRef);
		if (inent != INVALID_ENT_REFERENCE && GetEntPropEnt(this.Client, Prop_Send, "moveparent") == inent) {
			AcceptEntityInput(this.Client, "ClearParent", inent, -1, 0);
		}
		float pos[3];
		GetClientAbsOrigin(this.Client, pos);
		pos[2] += g_bury[this.Client].BuryDistance + 4;
		TeleportEntity(this.Client, pos, NULL_VECTOR, NULL_VECTOR);
		SetEntityCollisionGroup(this.Client, g_bury[this.Client].PreCollisionGroup);
		SetEntityMoveType(this.Client, g_bury[this.Client].PreMoveType);
		g_bury[this.Client].IsBuried = false;
		if (playSound) {
			char soundName[40];
			Format(soundName, sizeof(soundName), "physics/body/body_medium_break%i.wav", GetRandomInt(2,4));
			EmitSoundToAll(soundName, this.Client);
		}
	}
	property bool IsBuried {
		public get() { return g_bury[this.Client].IsBuried; }
	}
	public void Reset() {
		if (g_bury[this.Client].IsBuried) {
			SetEntityCollisionGroup(this.Client, g_bury[this.Client].PreCollisionGroup);
			SetEntityMoveType(this.Client, g_bury[this.Client].PreMoveType);
			int inent = EntRefToEntIndex(g_bury[this.Client].InEntityRef);
			if (inent != INVALID_ENT_REFERENCE && this.IsValid(true,false) && GetEntPropEnt(this.Client, Prop_Send, "moveparent") == inent) {
				AcceptEntityInput(this.Client, "ClearParent", inent, -1, 0);
			}
		}
		g_bury[this.Client].IsBuried = false;
		g_bury[this.Client].InEntityRef = INVALID_ENT_REFERENCE;
	}
}
public bool TRFilter_NoClients(int entity, int contentMask) {
	return !(1<=entity<=MaxClients);
}

public void OnPluginStart() {
	LoadTranslations("common.phrases");
	
	RegAdminCmd("sm_bury", Command_Bury, ADMFLAG_SLAY, "Usage: sm_bury <targets> - Bury a player in the ground, imobalizing them");
	RegAdminCmd("sm_unbury", Command_Unbury, ADMFLAG_SLAY, "Usage: sm_unbury <targets> - Bury a player in the ground, imobalizing them");
	RegAdminCmd("sm_rslap", Command_RSlap, ADMFLAG_SLAY, "Usage: sm_rslap <targets> [repeats=1] [delay=0.2] [damage=0] - Slap a player multiple times, delay is 0.02..0.5");
	
	AddCommandListener(Command_Kill, "kill")
	
	HookEvent("player_death", OnClientDeathPost);
	HookEvent("teamplay_round_start", OnMapEntitiesRefreshed);
	HookEvent("teamplay_restart_round", OnMapEntitiesRefreshed);
}

public void OnMapStart() {
	PrecacheSound("physics/body/body_medium_break2.wav");
	PrecacheSound("physics/body/body_medium_break3.wav");
	PrecacheSound("physics/body/body_medium_break4.wav");
}

public void OnPluginEnd() {
	UnburyAll();
}
public void OnMapEnd() {
	UnburyAll();
}
public void OnMapEntitiesRefreshed(Event event, const char[] name, bool dontBroadcast) {
	UnburyAll();
}
public void OnClientDeathPost(Event event, const char[] name, bool dontBroadcast) {
	Player target = Player(GetClientOfUserId(event.GetInt("userid", 0)));
	if (target.IsValid(true,false)) target.Reset();
}

static void UnburyAll() {
	for (int client=1; client <= MaxClients; client++) {
		Player target = Player(client);
		if (target.IsValid() && target.IsBuried) target.Unbury(false);
	}
}

public Action Command_Kill(int client, const char[] command, int argc) {
	if (Player(client).IsBuried) {
		ReplyToCommand(client, "[SM] You cannot do this right now");
		return Plugin_Handled;
	}
	return Plugin_Continue;
}
public Action Command_Bury(int client, int args) {
	if (!args) {
		ReplyToCommand(client, "Usage: sm_bury <targets>");
		return Plugin_Handled;
	}
	char pattern[128];
	GetCmdArgString(pattern, sizeof(pattern));
	int targets[MAXPLAYERS];
	char tname[64];
	bool tn_is_ml;
	int result = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_ALIVE, tname, sizeof(tname), tn_is_ml);
	if (result <= 0) {
		ReplyToTargetError(client, result);
	} else {
		ActBuryOn(targets, result, false);
		if (tn_is_ml) {
			ShowActivity2(client, "[SM] ", "%N buried %t in the ground", client, tname);
		} else {
			ShowActivity2(client, "[SM] ", "%N buried %s in the ground", client, tname);
		}
	}
	return Plugin_Handled;
}
public Action Command_Unbury(int client, int args) {
	if (!args) {
		ReplyToCommand(client, "Usage: sm_bury <targets>");
		return Plugin_Handled;
	}
	char pattern[128];
	GetCmdArgString(pattern, sizeof(pattern));
	int targets[MAXPLAYERS];
	char tname[64];
	bool tn_is_ml;
	int result = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_ALIVE, tname, sizeof(tname), tn_is_ml);
	if (result <= 0) {
		ReplyToTargetError(client, result);
	} else {
		ActBuryOn(targets, result, true);
		if (tn_is_ml) {
			ShowActivity2(client, "[SM] ", "%N unburied %t from the ground", client, tname);
		} else {
			ShowActivity2(client, "[SM] ", "%N unburied %s from the ground", client, tname);
		}
	}
	return Plugin_Handled;
}
void ActBuryOn(int[] targets, int numtargets, bool unbury=false) {
	for (int i=0;i<numtargets;i++) {
		Player target = Player(targets[i]);
		if (!target.IsValid() || target.IsBuried != unbury) continue;
		if (unbury) target.Unbury();
		else target.Bury();
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	if (Player(client).IsBuried && (buttons & (IN_JUMP|IN_DUCK|IN_FORWARD|IN_BACK|IN_MOVELEFT|IN_MOVERIGHT)) ) {
		buttons &=~ (IN_JUMP|IN_DUCK|IN_FORWARD|IN_BACK|IN_MOVELEFT|IN_MOVERIGHT);
		return Plugin_Changed;
	}
	return Plugin_Continue;
}


public Action Command_RSlap(int client, int args) {
	if (!args) {
		ReplyToCommand(client, "Usage: sm_rslap <targets> [repeats=1] [delay=0.2] [damage=0]");
		return Plugin_Handled;
	}
	char pattern[128];
	GetCmdArg(1, pattern, sizeof(pattern));
	int targets[MAXPLAYERS];
	char tname[64];
	bool tn_is_ml;
	int result = ProcessTargetString(pattern, client, targets, sizeof(targets), COMMAND_FILTER_ALIVE, tname, sizeof(tname), tn_is_ml);
	if (result <= 0) {
		ReplyToTargetError(client, result);
		return Plugin_Handled;
	}
	int repeats=1, damage=0;
	float delay=0.2;
	if (args>=2) {
		GetCmdArg(2, pattern, sizeof(pattern));
		if (StringToIntEx(pattern, repeats)!=strlen(pattern) || repeats < 1) {
			ReplyToCommand(client, "Repeats has to be positive integer");
			return Plugin_Handled;
		}
	}
	if (args>=3) {
		GetCmdArg(3, pattern, sizeof(pattern));
		if (StringToFloatEx(pattern, delay)!=strlen(pattern) || !(0.02<=delay<=0.5)) {
			ReplyToCommand(client, "Delay has to be between 0.02 .. 0.5");
			return Plugin_Handled;
		}
	}
	if (args>=4) {
		GetCmdArg(4, pattern, sizeof(pattern));
		if (StringToIntEx(pattern, damage)!=strlen(pattern) || damage < 0) {
			ReplyToCommand(client, "Damage has to be positive or zero integer");
			return Plugin_Handled;
		}
	}
	DataPack slapData = new DataPack();
	slapData.WriteCell(damage);
	slapData.WriteCell(result);
	for (int i=0;i<result;i++) {
		slapData.WriteCell(GetClientUserId(targets[i]));
	}
	slapData.WriteCell(repeats);
	CreateTimer(delay, Timer_RSlap, slapData, TIMER_REPEAT|TIMER_DATA_HNDL_CLOSE|TIMER_FLAG_NO_MAPCHANGE);
	if (tn_is_ml) {
		ShowActivity2(client, "[SM] ", "%N slapped %t repeatedly", client, tname);
	} else {
		ShowActivity2(client, "[SM] ", "%N slapped %s repeatedly", client, tname);
	}
	return Plugin_Handled;
}

public void OnEntityDestroyed(int entity) {
	//can't get the ent ref anymore, just validate all parents
	for (int client=1; client < MaxClients; client+=1) {
		Player target = Player(client);
		if (!target.IsValid() || !target.IsBuried) continue;
		if (GetEntPropEnt(client, Prop_Send, "moveparent") == entity) {
			AcceptEntityInput(client, "ClearParent", -1, -1, 0);
			target.Unbury();
		}
	}
}

public void OnEntityCreated(int entity, const char[] classname) {
	if (1<=entity<=MaxClients) {
		HookClient(entity);
	}
}

void HookClient(int client) {
	SDKHook(client, SDKHook_OnTakeDamagePost, OnClientTakeDamagePost);
}

public void OnClientTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype) {
	if (GetClientHealth(victim) <= 0) Player(victim).Reset();
}

public void OnClientConnected(int client) {
	Player(client).Reset();
}
public void OnClientDisconnect(int client) {
	Player(client).Reset();
}

public Action Timer_RSlap(Handle timer, DataPack data) {
	data.Reset();
	int damage = data.ReadCell();
	int targets[MAXPLAYERS];
	int numtargets;
	for (int i=data.ReadCell(); i>0; i-=1) {
		int client = GetClientOfUserId(data.ReadCell());
		if (Player(client).IsValid()) {
			targets[numtargets] = client;
			numtargets += 1;
		}
	}
	int repeats = data.ReadCell()-1;
	
	data.Reset(true);
	data.WriteCell(damage);
	data.WriteCell(numtargets);
	for (int i=0; i<numtargets; i+=1) {
		SlapPlayer(targets[i], damage);
		data.WriteCell(GetClientUserId(targets[i]));
	}
	data.WriteCell(repeats);
	
	return (repeats>0 && numtargets>0) ? Plugin_Continue : Plugin_Stop;
}
