#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2>
#include <tf2utils>
#include "include/playerbits.inc"

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w48a"
#define ENTITY_WORLD 0

public Plugin myinfo = {
	name = "VSH Wallclimb",
	author = "reBane, original by LizardOfOz",
	description = "Only the wallclimb",
	version = PLUGIN_VERSION,
	url = "N/A"
}

PlayerBits clientAllowed;
ConVar cvarAllowGrounded;
ConVar cvarGravity;
int clientHits[MAXPLAYERS+1];

//char classnames[10][16]={"", "scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer"};

public void OnPluginStart() {
	ConVar version = CreateConVar( "sm_wallclimb_version", PLUGIN_VERSION, "Wallclimb version", FCVAR_NOTIFY|FCVAR_DONTRECORD|FCVAR_REPLICATED );
	version.AddChangeHook(OnVersionChanged);
	version.SetString(PLUGIN_VERSION);
	cvarAllowGrounded = CreateConVar( "sm_wallclimb_allowgrounded", "0", "VSH allows wall climbing while grounded, set 1 to mimic this behaviour", FCVAR_DONTRECORD );
	
	cvarGravity = FindConVar("sv_gravity");
	
	for (int client=1;client<=MaxClients;client++) {
		if (IsClientInGame(client) && !IsFakeClient(client)) {
			OnEntityCreated(client, "player");
			if (IsClientAuthorized(client)) {
				OnClientPostAdminCheck(client);
			}
		}
	}
	for (int entity=MaxClients+1;entity<2048;entity++) {
		if (!IsValidEdict(entity)) continue;
		char classname[16];
		GetEdictClassname(entity, classname, sizeof(classname));
		OnEntityCreated(entity, classname);
	}
}

public void OnVersionChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!StrEqual(newValue, PLUGIN_VERSION)) {
		convar.SetString(PLUGIN_VERSION);
	}
}

public void OnMapStart() {
	SetEntProp(ENTITY_WORLD, Prop_Data, "m_takedamage", 1); //enable takedamage hook on world
	SDKHookEx(ENTITY_WORLD, SDKHook_OnTakeDamagePost, OnEntityTakeDamagePost);
}

public void OnClientPostAdminCheck(int client) {
	clientAllowed.Set(client, CheckCommandAccess(client, "wallclimb", 0));
}


public void OnEntityCreated(int entity, const char[] classname) {
	if (1<=entity<=MaxClients && StrEqual(classname, "player")) {
		SDKHookEx(entity, SDKHook_GroundEntChangedPost, OnEntityGroundEntChangedPost);
	} else if (strncmp(classname, "prop_", 5) == 0 || strncmp(classname, "func_", 5) == 0) {
		SDKHookEx(entity, SDKHook_OnTakeDamagePost, OnEntityTakeDamagePost);
	}
}

void OnEntityTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype) {
	if ( (damagetype & DMG_CLUB)!=0 && 1 <= attacker <= MaxClients && IsClientInGame(attacker) && IsPlayerAlive(attacker) ) {
		if (!clientAllowed.Get(attacker)) return;
		int activeWeapon = GetEntPropEnt(attacker, Prop_Data, "m_hActiveWeapon");
		bool isMelee = activeWeapon != INVALID_ENT_REFERENCE && TF2Util_GetWeaponSlot(activeWeapon) == TFWeaponSlot_Melee;
		bool isOnFloor = (GetEntityFlags(attacker) & FL_ONGROUND) != 0;
		if (isMelee && (cvarAllowGrounded.BoolValue || !isOnFloor)) PerformWallClimb(attacker);
	}
}

void OnEntityGroundEntChangedPost(int entity) {
	clientHits[entity] = 0;
}

void PerformWallClimb(int player, bool fromQuickFix = false) {
	//force off ground (for quick fix)
	SetEntPropEnt(player, Prop_Data, "m_hGroundEntity", INVALID_ENT_REFERENCE);
	SetEntityFlags(player, GetEntityFlags(player)&~FL_ONGROUND);
	
	// calculate and apply boost
	int hits = ++clientHits[player];
	float launchVelocity = cvarGravity.FloatValue;
	switch (hits) {
		case 1: launchVelocity *= 0.75;
		case 2: launchVelocity *= 0.5625;
		case 3,4: launchVelocity *= 0.5;
		default: launchVelocity *= 0.25;
	}
	
	float velocity[3];
	GetEntPropVector(player, Prop_Data, "m_vecAbsVelocity", velocity);
	if (hits == 2) {
		velocity[0] *= 0.5;
		velocity[1] *= 0.5;
	}
	if (hits <= 2) velocity[2] = launchVelocity;
	else velocity[2] += launchVelocity;
	TeleportEntity(player, _, _, velocity);
	
	if (fromQuickFix) return;
	// pull medics with us
	for(int otherPlayer=1; otherPlayer<=MaxClients; otherPlayer++) {
		if (!IsClientInGame(otherPlayer) || TF2_GetPlayerClass(otherPlayer)!=TFClass_Medic) 
			continue;
		int medigun = GetEntPropEnt(otherPlayer, Prop_Data, "m_hActiveWeapon");
		if (medigun == INVALID_ENT_REFERENCE || GetEntProp(medigun, Prop_Send, "m_iItemDefinitionIndex")!=411) 
			continue;//411 = quick fix
		int healTarget = GetEntPropEnt(medigun, Prop_Send, "m_hHealingTarget");
		if (healTarget == player)
			PerformWallClimb(otherPlayer, true);
	}
}

//sounds are packed into maps, dont wanna deal with that
//EmitPlayerVODelayed(player, "wall_climb", 0.2);
// cooldown: 20 seconds per player
//  to no more than 3 players per climb?
// chance: 33% if played less than 3 times recently, 20% otherwise
//  halfed for scout
