/** Example Plugin */

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smlib>

#include "include/playerpicker.inc"

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "23w03a"

public Plugin myinfo = {
	name = "TP Ask",
	author = "reBane",
	description = "Brings teleport requests to Source games",
	version = PLUGIN_VERSION,
	url = "http://forums.alliedmods.net"
};

enum {
	REQ_NONE = 0,
	REQ_GOTO = 1,
	REQ_BRING = 2,
	REQ_PENDING = 4,
	REQ_BLOCKED = 8
}

enum struct TPAData {
	int requester;
	int flags;
	Handle timeout;
	float nextRequest;
}

TPAData g_requests[MAXPLAYERS+1];
ConVar g_warmup;
ConVar g_cooldown;

//you can change this if you don't like the sounds, and toggle PLAYSOUNDS to disable them entirely
#define SND_TELEPORT1 "ambient/machines/teleport1.wav"
#define SND_TELEPORT2 "ambient/machines/teleport3.wav"
#define SND_TELEPORT3 "ambient/machines/teleport4.wav"
#define SND_WARMUP1 "vo/npc/vortigaunt/holdstill.wav" //"ambient/levels/labs/teleport_alarm_loop1.wav"
#define SND_WARMUP2 "vo/npc/vortigaunt/ifyoumove.wav"
#define SND_INTERRUPT2 "vo/npc/vortigaunt/regrettable.wav" //"ambient\machines\spindown.wav"
#define SND_INTERRUPT1 "vo/npc/vortigaunt/vanswer05.wav"
#define PLAYSOUNDS true

// SourceMod API

public void OnPluginStart() {
	LoadTranslations("common.phrases");
	
	RegAdminCmd("sm_tpa", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt to the target player", "tpask");
	RegAdminCmd("sm_tpask", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt to the target player", "tpask");
	RegAdminCmd("sm_gotoa", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt to the target player", "tpask");
	RegAdminCmd("sm_gotoask", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt to the target player", "tpask");
	RegAdminCmd("sm_tpahere", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt the target player to you", "tpask");
	RegAdminCmd("sm_tpaskhere", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt the target player to you", "tpask");
	RegAdminCmd("sm_bringa", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt the target player to you", "tpask");
	RegAdminCmd("sm_bringask", Command_TPAsk, ADMFLAG_GENERIC, "Uasge: <target> - Ask to teleprt the target player to you", "tpask");
	
	RegAdminCmd("sm_tpaccept", Command_TPAccept, ADMFLAG_GENERIC, "Accept the most recent teleport request", "tpask");
	RegAdminCmd("sm_tpdeny", Command_TPDeny, ADMFLAG_GENERIC, "Deny the most recent teleport request", "tpask");
	RegAdminCmd("sm_tptoggle", Command_TPToggle, ADMFLAG_GENERIC, "Deny the most recent teleport request", "tpask");
	
	g_warmup = CreateConVar("sm_tpa_warmup", "3", "Time in seconds the player has to stand still w/o taking damage before the accepted teleport goes through", _, true);
	g_cooldown = CreateConVar("sm_tpa_cooldown", "30", "Time after a successful tpa, before the player can request another one", _, true);
	AutoExecConfig();
	ConVar version = CreateConVar("sm_tpa_version", PLUGIN_VERSION, "TPAsk Version", FCVAR_DONTRECORD|FCVAR_NOTIFY);
	ConVarVersionLock(version,"","");
	version.AddChangeHook(ConVarVersionLock);
	delete version; //we don't need the handle anymore, the change-hook is enough
	
	//late load
	for (int client=1; client<=MaxClients; client+=1) {
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		OnClientConnected(client);
		HookPlayer(client);
	}
}

public void OnMapStart() {
#if PLAYSOUNDS
	PrecacheSound(SND_TELEPORT1);
	PrecacheSound(SND_TELEPORT2);
	PrecacheSound(SND_TELEPORT3);
	PrecacheSound(SND_WARMUP1);
	PrecacheSound(SND_WARMUP2);
	PrecacheSound(SND_INTERRUPT2);
	PrecacheSound(SND_INTERRUPT1);
#endif
}


public void ConVarVersionLock(ConVar convar, const char[] oldValue, const char[] newValue) {
	char buffer[12];
	convar.GetString(buffer, sizeof(buffer));
	if (!StrEqual(buffer, PLUGIN_VERSION)) {
		convar.SetString(PLUGIN_VERSION);
	}
}

public Action Command_TPAsk(int client, int args) {
	char buffer[MAX_TARGET_LENGTH];
	GetCmdArg(0, buffer, sizeof(buffer));
	bool reverse = StrContains(buffer, "here", false) >= 0 || StrContains(buffer, "bring", false) >= 0;
	
	GetCmdArgString(buffer, sizeof(buffer));
	TrimString(buffer);
	int targets[1];
	bool tn_is_ml;
	char target_name[32];
	int count;
	if (buffer[0])
		count = ProcessTargetString(buffer, client, targets, sizeof(targets), COMMAND_FILTER_ALIVE|COMMAND_FILTER_NO_MULTI|COMMAND_FILTER_NO_BOTS|COMMAND_FILTER_NO_IMMUNITY, target_name, sizeof(target_name), tn_is_ml);
	if (count < 0) {
		ReplyToTargetError(client, count);
	} else if (count == 0) {
		DataPack request = new DataPack();
		request.WriteCell(reverse);
		request.WriteCell(GetClientUserId(client));
		request.Reset();
		PickPlayer(client, COMMAND_FILTER_ALIVE|COMMAND_FILTER_NO_BOTS, ThenRequestTeleport, request);
	} else {
		RequestTeleport(client, targets[0], reverse);
	}
	return Plugin_Handled;
}
void ThenRequestTeleport(int target, any data) {
	DataPack request = view_as<DataPack>(data);
	bool bring = request.ReadCell();
	int requester = GetClientOfUserId(request.ReadCell());
	delete request;
	
	if (target <= COMMAND_TARGET_CANCELLED) return;
	RequestTeleport(requester, target, bring);
}

public Action Command_TPAccept(int client, int args) {
	if (!(g_requests[client].flags & REQ_PENDING) || !AcceptTeleport(client)) {
		ReplyToCommand(client, "[SM] No pending teleport request");
	}
	return Plugin_Handled;
}
public Action Command_TPDeny(int client, int args) {
	if (!(g_requests[client].flags & REQ_PENDING) || !InterruptTeleport(client)) {
		ReplyToCommand(client, "[SM] No pending teleport request");
	}
	return Plugin_Handled;
}
public Action Command_TPToggle(int client, int args) {
	bool allow = !(g_requests[client].flags & REQ_BLOCKED);
	if (allow) {
		g_requests[client].flags |= REQ_BLOCKED;
		ReplyToCommand(client, "[SM] You no longer receive teleport requests");
	} else {
		g_requests[client].flags &=~ REQ_BLOCKED;
		ReplyToCommand(client, "[SM] People can now ask you to teleport");
	}
	return Plugin_Handled;
}


public void OnClientConnected(int client) {
	g_requests[client].requester = 0;
	g_requests[client].flags = REQ_NONE;
	g_requests[client].nextRequest = 0.0;
}
public void OnClientDisconnect(int client) {
	int timerAt = GetTeleportingRequest(client);
	if (timerAt) CancelTimer(g_requests[timerAt].timeout);
	OnClientConnected(client);
}

void CheckPlayerWarmup(int client) {
	if (!IsRequestSensitive(client)) return;
	
	int moveme, tohere;
	if (!GetRequestClients(client, moveme, tohere)) return;
	
	float vel[3];
	Entity_GetLocalVelocity(moveme, vel);
	if (GetVectorLength(vel, true) > 10.0) {
		InterruptTeleport(client);
	}
}

public void OnEntityCreated(int entity, const char[] classname) {
	if (StrEqual(classname, "player")) {
		HookPlayer(entity);
	}
}
void HookPlayer(int client) {
	if (!IsClientInGame(client) || IsFakeClient(client)) return;
	SDKHook(client, SDKHook_OnTakeDamagePost, OnClientTakeDamagePost);
}
public void OnClientTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype) {
	int request = GetTeleportingRequest(victim);
	if (!IsRequestSensitive(request)) return;
	
	int moveme, tohere;
	if (!GetRequestClients(request, moveme, tohere)) return;
	
	if (victim == moveme) {
		InterruptTeleport(request);
	}
}

// Implementation

bool RequestTeleport(int client, int target, bool bring) {
	if (g_requests[target].flags & REQ_BLOCKED) {
		PrintToChat(client, "[SM] You can't ask %N for teleports", target);
		return false;
	}
	if (g_requests[target].timeout != INVALID_HANDLE) {
		PrintToChat(client, "[SM] %N already has a pending teleport request", target);
		return false;
	}
	if (g_requests[client].timeout != INVALID_HANDLE || (!IsFakeClient(client) && GetClientTime(client) < g_requests[client].nextRequest)) {
		PrintToChat(client, "[SM] You can't request another teleport yet", target);
		return false;
	}
	
	g_requests[target].requester = GetClientUserId(client);
	g_requests[target].flags = (bring?REQ_BRING:REQ_GOTO) | REQ_PENDING;
	g_requests[target].timeout = CreateTimer(30.0, Timer_CancelRequest, GetClientUserId(target), TIMER_FLAG_NO_MAPCHANGE);
	
	if (bring) {
		PrintToChat(target, "\x01[SM] \x07646464%N\x01 wants you to teleport to them. Respond with \x0732CD32/tpaccept\x01 or \x07B22222/tpdeny\x01.", client);
		PrintToChat(client, "[SM] You've asked to teleport %N to you...", target);
	} else {
		PrintToChat(target, "\x01[SM] \x07646464%N\x01 wants to teleport to you. Respond with \x0732CD32/tpaccept\x01 or \x07B22222/tpdeny\x01.", client);
		PrintToChat(client, "[SM] You've asked to teleport to %N...", target);
	}
	PrintToChat(target, "\x01[SM] You can toggle ignoring requests with \x074682B4/tptoggle\x01.");
	
	return true;
}

public Action Timer_CancelRequest(Handle timer, any userid) {
	int target = GetClientOfUserId(userid);
	if (!target) return Plugin_Stop;
	int client = GetClientOfUserId(g_requests[target].requester);
	if (client) {
		PrintToChat(client, "[SM] %N denied your teleport request", target);
	}
	
	g_requests[target].requester = 0;
	g_requests[target].flags &=~ (REQ_PENDING|REQ_GOTO|REQ_BRING);
	CancelTimer(g_requests[target].timeout);
	return Plugin_Stop;
}

bool AcceptTeleport(int target) {
	if (!(g_requests[target].flags & REQ_PENDING)) {
		PrintToChat(target, "[SM] There's currently to pending teleport request");
		return false;
	}
	
	int moveme, tohere;
	if (!GetRequestClients(target, moveme, tohere)) return false;
	
	g_requests[target].flags &=~ REQ_PENDING;
	CancelTimer(g_requests[target].timeout);
	
	if (g_warmup.FloatValue>0.1) {
#if PLAYSOUNDS
		switch (GetRandomInt(1,2)) {
			case 1: {
				EmitSoundToClient(moveme, SND_WARMUP1);
			}
			case 2: {
				EmitSoundToClient(moveme, SND_WARMUP2);
			}
		}
#endif
		PrintToChat(moveme, "[SM] Your teleport is warming up (%is), hold still!", RoundToCeil(g_warmup.FloatValue));
		PrintToChat(tohere, "[SM] The teleport for %N is starting...", moveme);
		g_requests[target].timeout = CreateTimer(g_warmup.FloatValue, Timer_Teleport, GetClientUserId(target), TIMER_FLAG_NO_MAPCHANGE);
	} else {
		Timer_Teleport(INVALID_HANDLE, GetClientUserId(target));
	}
	return true;
}
public Action Timer_Teleport(Handle timer, any userid) {
	int target = GetClientOfUserId(userid);
	int moveme, tohere;
	if (!GetRequestClients(target, moveme, tohere)) return Plugin_Stop;
	int requester = target == moveme ? tohere : moveme; //requester is the one of <moveme,tohere> that is not target
	
	CheckPlayerWarmup(moveme); //teleporting client should stop moving before tp
	
	float pos[3];
	if (!FindSaveTPLocationAround(tohere, pos, moveme)) {
#if PLAYSOUNDS
		float from[3];
		GetClientAbsOrigin(moveme, from);
		switch (GetRandomInt(1,2)) {
			case 1: {
				EmitSoundToClient(moveme, SND_INTERRUPT1);
			}
			case 2: {
				EmitSoundToClient(moveme, SND_INTERRUPT2);
			}
		}
#endif
		PrintToChat(tohere, "[SM] Could not find a valid position to teleport %N to you", moveme);
		PrintToChat(moveme, "[SM] Could not find a valid position around %N to teleport you to", tohere);
	} else {
#if PLAYSOUNDS
		float from[3];
		GetClientAbsOrigin(moveme, from);
		switch (GetRandomInt(1,3)) {
			case 1: {
				EmitSoundToClient(moveme, SND_TELEPORT1); //client moves into pos, not playing it?
				EmitSoundToAll(SND_TELEPORT1, SOUND_FROM_WORLD, _, _, _, _, _, _, pos);
			}
			case 2: {
				EmitSoundToClient(moveme, SND_TELEPORT2);
				EmitSoundToAll(SND_TELEPORT2, SOUND_FROM_WORLD, _, _, _, _, _, _, pos);
			}
			case 3: {
				EmitSoundToClient(moveme, SND_TELEPORT3);
				EmitSoundToAll(SND_TELEPORT3, SOUND_FROM_WORLD, _, _, _, _, _, _, pos);
			}
		}
#endif
		TeleportEntity(moveme, pos, NULL_VECTOR, NULL_VECTOR);
		if (!IsFakeClient(requester))
			g_requests[requester].nextRequest = GetClientTime(requester) + g_cooldown.FloatValue;
	}
	//done
	g_requests[target].flags &=~ (REQ_PENDING|REQ_GOTO|REQ_BRING);
	g_requests[target].requester = 0;
	g_requests[target].timeout = INVALID_HANDLE;
	return Plugin_Stop;
}
bool FindSaveTPLocationAround(int client, float location[3], int tomove) {
	float tmins[3], tmaxs[3], mmins[3], mmaxs[3], aux[3], pos[3];
	GetClientMins(client, tmins);
	GetClientMaxs(client, tmaxs);
	GetClientMins(tomove, mmins);
	GetClientMaxs(tomove, mmaxs);
	GetClientAbsOrigin(client, pos);
	
	//compute distance from client to not get stuck
	float swidth = FMax(mmaxs[0]-mmins[0], mmaxs[1]-mmins[1]) +
	               FMax(tmaxs[0]-tmins[0], tmaxs[1]-tmins[1]) + 
	               3.0; //safety
	swidth /= 2.0; //half for center-center distance
	
	//try all 4 cardianl directions, starting with the one closest to where client is looking
	GetClientAbsAngles(client, aux);
	float yaw = IWrapValue(RoundToNearest( aux[1] / 360.0 ), -2, 2) * 3.141592 / 2.0; //to 90deg|.5pi steps
	for (int dir=0; dir<4; dir+=1) {
		aux[0] = Cosine(yaw) * swidth;
		aux[1] = Sine(yaw) * swidth;
		aux[2] = 0.0;
		AddVectors(aux,pos,aux);
		if (TraceFreeSpace(aux, mmins, mmaxs)) {
			location = aux;
			return true;
		}
		yaw = FWrapValue(yaw + 3.141592/2.0, -3.141592, 3.141592);
	}
	
	//try above the player?
	pos[2] += tmaxs[2] + 3.0;
	if (TraceFreeSpace(pos, mmins, mmaxs)) {
		location = pos;
		return true;
	}
	
	//no location found
	return false;
}
bool TraceFreeSpace(float pos[3], const float mins[3], const float maxs[3]) {
	float start[3], end[3];
	start = pos;
	start[2] += 20.0; // 20.0u above the player to teleport to
	end = pos;
	//we could handle a entity filter, but i can't think of anything to filter for
	TR_TraceHull(start, end, mins, maxs, MASK_PLAYERSOLID);
	return !TR_DidHit() || TR_GetEntityIndex()==-1;
}
float FMax(float a, float b) {
	return a>b?a:b;
}
int IWrapValue(int value, int min, int max) {
	int span = max-min;
	while (value <= min) value += span; //min exclusive
	while (value > max) value -= span;
	return value;
}
float FWrapValue(float value, float min, float max) {
	float span = max-min;
	while (value <= min) value += span; //min exclusive
	while (value > max) value -= span;
	return value;
}

bool InterruptTeleport(int target) {
	int moveme, tohere;
	if (!GetRequestClients(target, moveme, tohere)) return false;
	
#if PLAYSOUNDS
	float from[3];
	GetClientAbsOrigin(moveme, from);
	switch (GetRandomInt(1,2)) {
		case 1: {
			EmitSoundToClient(moveme, SND_INTERRUPT1);
		}
		case 2: {
			EmitSoundToClient(moveme, SND_INTERRUPT2);
		}
	}
#endif
	PrintToChat(tohere, "[SM] The teleport for %N was interrupted", moveme);
	PrintToChat(moveme, "[SM] Your teleport to %N was interrupted", tohere);
	
	g_requests[target].flags &=~ (REQ_PENDING|REQ_GOTO|REQ_BRING);
	g_requests[target].requester = 0;
	CancelTimer(g_requests[target].timeout);
	return true;
}

int GetTeleportingRequest(int client) {
	if (g_requests[client].timeout != INVALID_HANDLE) return client;
	int uid = GetClientUserId(client);
	for (int probe=1;probe<MaxClients;probe+=1) {
		if (g_requests[probe].requester == uid) return probe;
	}
	return 0;
}

bool GetRequestClients(int target, int& moveme, int& tohere) {
	if (!target) return false;
	int requester = GetClientOfUserId(g_requests[target].requester);
	if (g_requests[target].timeout == INVALID_HANDLE) return false;
	
	bool bring;
	if (g_requests[target].flags & REQ_BRING) bring = true;
	else if (!(g_requests[target].flags & REQ_GOTO)) return false; //invalid state
	
	if (bring) {
		moveme = target;
		tohere = requester;
	} else {
		moveme = requester;
		tohere = target;
	}
	return true;
}
bool IsRequestSensitive(int request) {
	return request && (g_requests[request].flags & (REQ_GOTO|REQ_BRING)) && !(g_requests[request].flags & REQ_PENDING);
}
void CancelTimer(Handle& timer) {
	if (timer != INVALID_HANDLE) KillTimer(timer);
	timer = INVALID_HANDLE;
}

//void TraceLine(int client, float a[3], float b[3], int color[4]) {
//	static int g_iLaserBeam = -1;
//	if (g_iLaserBeam<0) g_iLaserBeam = PrecacheModel("materials/sprites/laserbeam.vmt");
//	TE_SetupBeamPoints(a, b, g_iLaserBeam, 0, 0, 1, 1.0, 2.0, 2.0, 0, 0.0, color, 0);
//	TE_SendToClient(client);
//}
