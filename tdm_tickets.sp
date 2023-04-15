#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "22w20a"

#define TEAM_RED 2
#define TEAM_BLUE 3

public Plugin myinfo = {
	name = "[TF2] TDM Tickets",
	author = "reBane",
	description = "Battlefield like Ticket system for TDM",
	version = PLUGIN_VERSION,
	url = "N/A"
}

ConVar cvar_mp_tournament;
ConVar cvar_mp_tournament_blueteamname;
ConVar cvar_mp_tournament_redteamname;
ConVar cvar_sm_tdm_tickets;

int g_iTickets[5];
bool g_bWaitingForPlayers;
bool g_bActive; //fake mp tournament? (only fake while game is running so the hud doesn't pop up)

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	if (late) {
		strcopy(error, err_max, "Don't feel like supporting late loading, change map please");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}


public void OnPluginStart() {
	cvar_mp_tournament = FindConVar("mp_tournament");
	cvar_mp_tournament_blueteamname = FindConVar("mp_tournament_blueteamname");
	cvar_mp_tournament_redteamname = FindConVar("mp_tournament_redteamname");
	cvar_sm_tdm_tickets = CreateConVar("sm_tdm_tickets", "200", "Number of kills required until a team scores a point", FCVAR_HIDDEN, true, 0.0);
	cvar_sm_tdm_tickets.AddChangeHook(OnConVarChanged_sm_tdm_tickets);
	
	HookEvent("teamplay_round_start", OnRoundStart, EventHookMode_Post);
	
	CreateTimer(0.5, Timer_TicketUpdate, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConVarChanged_sm_tdm_tickets(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_iTickets[4] = convar.IntValue;
	if (g_iTickets[2] > g_iTickets[4]) g_iTickets[2] = g_iTickets[4];
	if (g_iTickets[3] > g_iTickets[4]) g_iTickets[3] = g_iTickets[4];
}

public Action Timer_TicketUpdate(Handle timer) {
	if (g_iTickets[TEAM_BLUE] != g_iTickets[TEAM_BLUE-2]) {
		g_iTickets[TEAM_BLUE-2] = g_iTickets[TEAM_BLUE];
		SendConVarValueAll(cvar_mp_tournament_blueteamname, "Tickets: %i", g_iTickets[TEAM_BLUE]);
	}
	if (g_iTickets[TEAM_RED] != g_iTickets[TEAM_RED-2]) {
		g_iTickets[TEAM_RED-2] = g_iTickets[TEAM_RED];
		SendConVarValueAll(cvar_mp_tournament_redteamname, "Tickets: %i", g_iTickets[TEAM_RED]);
	}
	return Plugin_Continue;
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast) {
	g_iTickets[4] = g_iTickets[2] = g_iTickets[3] = cvar_sm_tdm_tickets.IntValue;
	if (!g_bWaitingForPlayers) SetTournamentMode(true);
}
public void OnRoundActive(Event event, const char[] name, bool dontBroadcast) {
	SetTournamentMode(true);
}
//don't show the hud by ignoring turnament mode during WFP
public void TF2_OnWaitingForPlayersStart() {
	g_bWaitingForPlayers = true;
	SetTournamentMode(false);
}
public void TF2_OnWaitingForPlayersEnd() {
	g_bWaitingForPlayers = false;
	SetTournamentMode(true);
}

public void OnMapEnd() {
	SetTournamentMode(false);
}


public void OnClientPutInServer(int client) {
	if (!IsFakeClient(client))
		SendConVarValue(client, cvar_mp_tournament, g_bActive?"1":"0");
}


public void OnEntityCreated(int entity, const char[] classname) {
	if (StrEqual(classname, "player")||StrEqual(classname, "tf_bot")) {
		SDKHook(entity, SDKHook_OnTakeDamagePost, OnClientTakeDamagePost);
	}
}
void OnClientTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype) {
	int team;
	if (g_bActive //only count scores/wins if active
	&& GetClientHealth(victim) <= 0 //if victim died
	&& victim != attacker //no suicide
	&& IsClientValid(victim, .allowBots=true) //?
	&& IsClientValid(attacker, .allowBots=true) //no death by world or anything funky
	&& (team=GetClientTeam(victim)) != GetClientTeam(attacker)) { //no team kill
		g_iTickets[team] -= 1;
		if (g_iTickets[team] <= 0) {
			//make the other team win
			ForceRoundWin(team==TEAM_RED?TEAM_BLUE:TEAM_RED);
		}
	}
}

static void SetTournamentMode(bool active) {
	if (g_bActive == active) return;
	g_bActive = active;
	SendConVarValueAll(cvar_mp_tournament, active?"1":"0");
}
static void ForceRoundWin(int team) {
	if (team < 0 || team > 3)
		ThrowError("Invalid Team Number %i", team);
	else if (team == 1)
		team = 0;
	
	//needs to be updated manually?
	SetTeamScore(team, GetTeamScore(team)+1);
	//change names backs for display
	g_bActive = false;
	
	if (team < 0 || team > 3)
		ThrowError("Invalid Team Number %i", team);
	else if (team == 1)
		team = 0;
	//find or create entity
	int entity = FindEntityByClassname(MaxClients+1, "game_round_win");
	if (entity == INVALID_ENT_REFERENCE)
		entity = CreateEntityByName("game_round_win");
	if (IsValidEntity(entity))
		DispatchSpawn(entity);
	else
		ThrowError("Unable to create game_round_win");
	//win
	SetVariantInt(team);
	AcceptEntityInput(entity, "SetTeam");
	AcceptEntityInput(entity, "RoundWin");
}
/** replicate fake value to all clients */
static void SendConVarValueAll(ConVar conVar, const char[] format, any...) {
	char buffer[128];
	VFormat(buffer, sizeof(buffer), format, 3);
	for (int client=1;client<=MaxClients;client++) {
		if (IsClientInGame(client)&&!IsFakeClient(client)) {
			SendConVarValue(client, conVar, buffer);
		}
	}
}
static bool IsClientValid(int client, bool allowBots=false) {
	return (1<=client<=MaxClients) && IsClientInGame(client) && (allowBots||!IsFakeClient(client));
}