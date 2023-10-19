#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "23w42b"

public Plugin myinfo = {
	name = "Spec Ghost",
	author = "reBane",
	description = "Spawns a ghost for every spectator to visualize their position",
	version = PLUGIN_VERSION,
	url = "https://github.com/DosMike"
}

enum ObserverMode {
    OBS_MODE_NONE = 0,	// not in spectator mode
	OBS_MODE_DEATHCAM,	// special mode for death cam animation
	OBS_MODE_FREEZECAM,	// zooms to a target, and freeze-frames on them
	OBS_MODE_FIXED,		// view from a fixed camera position
	OBS_MODE_IN_EYE,	// follow a player in first person view
	OBS_MODE_CHASE,		// follow a player in third person view
	OBS_MODE_POI,		// PASSTIME point of interest - game objective, big fight, anything interesting; added in the middle of the enum due to tons of hard-coded "<ROAMING" enum compares
	OBS_MODE_ROAMING,	// free roaming
}

bool clientSpectating[MAXPLAYERS+1] = {false, ...};
int clientGhosts[MAXPLAYERS+1] = {-1, ...};
int clientOldTeam[MAXPLAYERS+1] = {0, ...};

public void OnPluginStart() {
    HookEventEx("player_team", OnPlayerChangeTeam, EventHookMode_Post);
    for (int i=1; i<=MAXPLAYERS; i++) clientGhosts[i] = INVALID_ENT_REFERENCE;
}

public void OnPluginEnd() {
    OnMapEnd();
}

void OnPlayerChangeTeam(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    int team = event.GetInt("team");
    int oldteam = event.GetInt("oldteam");
    int disconnect = event.GetBool("disconnect");
    if (!client || team == 0 || team == oldteam || disconnect) return; //invalid

    clientOldTeam[client] = oldteam;
    FlagClientSpectatig(client, team == 1);
}

public void OnClientConnected(int client) {
    clientOldTeam[client] = 0;
    clientGhosts[client] = INVALID_ENT_REFERENCE;
    clientSpectating[client] = false;
}

public void OnClientDisconnect(int client) {
    FlagClientSpectatig(client, false);
    OnClientConnected(client);
}

public void OnMapStart() {
    //pretty sure DispatchKV "model" does precache, but whatever
    PrecacheModel("models/props_halloween/smlprop_ghost.mdl");
}

public void OnMapEnd() {
    for (int i=1; i<=MAXPLAYERS; i++) 
        FlagClientSpectatig(i, false);
}

void FlagClientSpectatig(int client, bool yes) {
    clientSpectating[client] = yes;
    if (!yes && clientGhosts[client] != INVALID_ENT_REFERENCE) 
        DeleteGhost(client);
}

void CheckGhost(int client) {
    if (!clientSpectating[client]) return;
    ObserverMode mode = view_as<ObserverMode>(GetEntProp(client, Prop_Send, "m_iObserverMode"));
    bool shouldGhost = (mode == OBS_MODE_ROAMING);
    bool stateOk = shouldGhost == (clientGhosts[client] != INVALID_ENT_REFERENCE);
    if (!stateOk) {
        if (shouldGhost) CreateGhost(client);
        else DeleteGhost(client);
    } else if (shouldGhost) {
        //update pos
        float pos[3];
        float ang[3];
        float up[3];
        GetClientEyePosition(client, pos);
        GetClientEyeAngles(client, ang);
        GetAngleVectors(ang, NULL_VECTOR, NULL_VECTOR, up);
        ScaleVector(up, 4.0);
        SubtractVectors(pos, up, pos);
        TeleportEntity(clientGhosts[client], pos, ang, NULL_VECTOR);
        SetEntProp(clientGhosts[client], Prop_Send, "m_flSimulationTime", GetGameTime());
    }
}

void CreateGhost(int client) {
    int entity = CreateEntityByName("prop_dynamic");
    DispatchKeyValue(entity, "model", "models/props_halloween/smlprop_ghost.mdl");
    if (!DispatchSpawn(entity) || !ActivateEntity(entity)) {
        RemoveEntity(entity);
        clientSpectating[client] = false; //we're buggin out, dont try again
    }
    float pos[3];
    float ang[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, ang);
    TeleportEntity(entity, pos, ang, NULL_VECTOR);
    SetEntityRenderMode(entity, RENDER_TRANSALPHA);
    SetEntityCollisionGroup(entity, 0); //COLLISION_GROUP_NONE?
    int r=255, g=150, b=255, a=100;
    if (clientOldTeam[client] != 2) r = 150;
    if (clientOldTeam[client] != 3) b = 150;
    SetEntityRenderColor(entity, r,g,b,a);
    clientGhosts[client] = entity;
}

void DeleteGhost(int client) {
    if (clientGhosts[client] != INVALID_ENT_REFERENCE) {
        AcceptEntityInput(clientGhosts[client], "Kill");
        clientGhosts[client] = INVALID_ENT_REFERENCE;
    }
}

public void OnGameFrame() {
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client)) continue;
        CheckGhost(client);
    }
}
