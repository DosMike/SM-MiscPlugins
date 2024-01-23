#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <halflife>
#include <tf2_stocks>
#include <tf2utils>
#include "include/particles.inc"

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w52c"

public Plugin myinfo = {
	name = "[TF2] Fart Combat",
	author = "reBane",
	description = "Space for longjump",
	version = PLUGIN_VERSION,
	url = "N/A"
}

#define COOLDOWN 1.0
#define FARTSOUNDS 2

int notButtons = ~(IN_ATTACK|IN_ATTACK2);
int clientPrevButtons[MAXPLAYERS+1];
float clientLastFart[MAXPLAYERS+1];
ConVar cvarActive;
bool active;
ConVar cvarBlockGuns;
bool blockGuns;
ConVar cvarFartDamage;
float fartDamage;

char farts[][] = {
	"gameplay/airblast1.wav",
	"gameplay/airblast2.wav",
};

public void OnPluginStart() {
	cvarActive = CreateConVar("mp_fartcombat", "0", "1 to enable", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cvarBlockGuns = CreateConVar("mp_fartnoguns", "1", "1 to disable weapons while farting", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cvarFartDamage = CreateConVar("mp_fartdamage", "100", "famage of farts", FCVAR_NOTIFY, true, 0.0);
	cvarActive.AddChangeHook(OnCVarActiveChanged);
	cvarBlockGuns.AddChangeHook(OnCVarBlockGunsChanged);
	cvarFartDamage.AddChangeHook(OnCVarDamageChanged);
	OnCVarActiveChanged(cvarActive, "", "");
	OnCVarBlockGunsChanged(cvarBlockGuns, "", "");
	OnCVarDamageChanged(cvarFartDamage, "", "");
	char buffer[PLATFORM_MAX_PATH];
	for (int i; i < FARTSOUNDS; i++) {
		FormatEx(buffer, sizeof(buffer), "sound/%s", farts[i]);
		AddFileToDownloadsTable(buffer);
	}
}

public void OnMapStart() {
	PrecacheParticleSystem("breadjar_impact");
	for (int i; i < FARTSOUNDS; i++) {
		PrecacheSound(farts[i]);
	}
}

public void OnMapEnd() {
	cvarActive.SetInt(0);
}


public void OnCVarActiveChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	active = (convar.IntValue != 0);
}
public void OnCVarBlockGunsChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	blockGuns = (convar.IntValue != 0);
}
public void OnCVarDamageChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	fartDamage = float(RoundToNearest( convar.FloatValue ));
}

public void OnClientDisconnect(int client) {
	clientLastFart[client] = 0.0;
	clientPrevButtons[client] = 0;
}


public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client) || !active) return Plugin_Continue;
	if (blockGuns) buttons &= notButtons;
	if ((clientPrevButtons[client]&IN_JUMP)==0 && (buttons&IN_JUMP)!=0 && GetClientTime(client)-clientLastFart[client] >= COOLDOWN) {
		DoFart(client);
	}
	clientPrevButtons[client] = buttons;
	return Plugin_Changed;
}

public bool TREF_NotEntity(int entity, int contentsMask, any data) {
	return entity != data;
}


void DoFart(int client) {
	int idx = GetRandomInt(0, FARTSOUNDS-1);
	EmitSoundToAll(farts[idx], client, SNDCHAN_WEAPON);
	
	//jump
	float ang[3], fwd[3];
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	float push[3];
	push = fwd;
	ScaleVector(push, 520.0);
	push[2] += 150.0;
	int flags = GetEntityFlags(client);
	if ((flags & FL_ONGROUND)==0) push[2] += 200.0;
	TeleportEntity(client, _, _, push);
	//effect
	push = fwd;
	ScaleVector(push, -72.0);
	push[2] = 56.0;
	if (ang[0] > 180.0) ang[0] -= 180.0;
	else ang[0] += 180.0;
	float point[3]={0.0, 0.0, -48.0};
	int attpt = LookupEntityAttachment(client, "back_lower");
	TE_StartParticle("breadjar_impact", push, point, ang, client, PATTACH_POINT, attpt);
	TE_SendToAll();
	//attack
	int myTeam = GetClientTeam(client);
	float myPos[3], pos[3], look[3], diff[3];
	GetClientEyeAngles(client, ang); //reset fwd
	GetAngleVectors(ang, look, NULL_VECTOR, NULL_VECTOR);
	GetClientAbsOrigin(client, myPos);
	myPos[2] += 48.0;
	bool amMedic = (TF2_GetPlayerClass(client) == TFClass_Medic);
	for (int player=1; player<=MaxClients; player++) {
		if (!IsClientInGame(player) || !IsPlayerAlive(player)) continue;
		GetClientAbsOrigin(player, pos);
		pos[2] += 48.0;
		SubtractVectors(myPos, pos, diff);
		if (GetVectorDotProduct(look, diff) >= 0.8 && GetVectorDistance(myPos, pos, true) <= 16384.0) {
			TR_TraceRayFilter(pos, myPos, MASK_SHOT, RayType_EndPoint, TREF_NotEntity, client);
			if (!TR_DidHit()||TR_GetEntityIndex()!=player) continue;
			if (GetClientTeam(player)!=myTeam)
				SDKHooks_TakeDamage(player, client, client, (amMedic?0.5:1.0)*fartDamage, DMG_NERVEGAS|DMG_ALWAYSGIB, _, fwd, push, false);
			else if (amMedic)
				TF2Util_TakeHealth(player, TF2Util_GetPlayerMaxHealthBoost(player, false, true)/6.0); // give 2/3 (=w/o overheal) and *0.25
		}
	}
	//other stuff
	if (TF2_IsPlayerInCondition(client, TFCond_Cloaked)) {
		TF2_RemoveCondition(client, TFCond_Cloaked);
		TF2_AddCondition(client, TFCond_CloakFlicker, 1.0, client);
	}
	SetEntPropFloat(client, Prop_Send, "m_flCloakMeter", 0.0);
	//book keeping
	clientLastFart[client] = GetClientTime(client);
}
