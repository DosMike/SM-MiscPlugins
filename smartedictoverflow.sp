#define PLUGIN_VERSION "23w48a"
#include <sdktools>
#include <sdkhooks>
#include <entity>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
	name = "Smart Edict Overflow Prevention",
	author = "reBane",
	version = PLUGIN_VERSION,
	description = "Provides a softer edict limit that doesn't reset"
};

ArrayList bin;
ArrayList stale; //one timestamp per stale edict index. upon deletion, an index becomes stale for roughly 1.5 seconds before it can be reused
int g_iMapLimit; //store an estimate of all edicts used by the map alone
bool g_bMapChange = true;
bool g_bWarned = false;
#define PLAYER_EDICTS (GetClientCount()*g_iEdictsPerPlayer + 12)
#define PANIC_CLEAR_THRESHOLD 24

#define ENTITY_STALE_TIME 1.5

#define HISTORY_SIZE 60
int g_iHistoryAt[HISTORY_SIZE];
int g_iHistoryMaxTf=0; //maximum recorded edicts for the next entry
int g_iHistoryWrite=0;

int g_iEdictLimit=2020;
ConVar cvarEdictLimit;
int g_iEdictLimitWarn=2000;
ConVar cvarEdictWarnLimit;
ConVar cvarEdictWarnOverlay;
int g_iEdictAction=1;
ConVar cvarEdictAction;
int g_iEdictsPerPlayer=11;
ConVar cvarEdictReserve;
ConVar cvarLowedictAction;
ConVar cvarLowedictThreshold;
//the edicts we count (vs GetEntityCount() <- desyncs sometimes)
// how/when does it desync: when plugins use RemoveEdict
int g_iEdictsCounted;
bool g_bEdictCounterDesync=false;
Handle g_hSecondTimer;

bool clientShowInfo[MAXPLAYERS+1];

enum {
	EdictAction_BlockSpawn = (1<<0),
	EdictAction_DeleteOldest = (1<<1)
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	if (late) RequestFrame(StartTracking);
	return APLRes_Success;
}

public void OnPluginStart() {
	int edictLimit = GetMaxEntities()-PANIC_CLEAR_THRESHOLD;
	CreateConVar("seop_version", PLUGIN_VERSION, "Smart Edict Overflow Prevention Version", FCVAR_SPONLY|FCVAR_DONTRECORD|FCVAR_NOTIFY);
	cvarEdictLimit = CreateConVar("seop_edictlimit", "2000", "Maximum number of edicts to keep around before limiting", FCVAR_ARCHIVE|FCVAR_DONTRECORD|FCVAR_NOTIFY, true, 512.0, true, float(edictLimit));
	cvarEdictWarnLimit = CreateConVar("seop_edictlimitwarn", "1950", "If edicts exceed this amount, a warning will be chatted (0 to disable)", FCVAR_ARCHIVE|FCVAR_DONTRECORD|FCVAR_NOTIFY, true, 0.0, true, float(GetMaxEntities()));
	cvarEdictWarnOverlay = CreateConVar("seop_edictlimitwarn_hudflags", "*", "Empty to disable hud, * to show all, single flag otherwise", FCVAR_ARCHIVE|FCVAR_DONTRECORD|FCVAR_NOTIFY, true, 0.0, true, float(GetMaxEntities()));
	cvarEdictAction = CreateConVar("seop_edictaction", "2", "0=prevent spawning, 1=delete oldest, 2=both", FCVAR_ARCHIVE|FCVAR_DONTRECORD|FCVAR_NOTIFY, true, 0.0, true, 2.0);
	cvarEdictReserve = CreateConVar("seop_edictsperplayer", "11", "Reserve a base amount of edicts per player. Empirically around 10 are required", FCVAR_ARCHIVE|FCVAR_DONTRECORD|FCVAR_NOTIFY, true, 10.0);
	cvarLowedictThreshold = FindConVar("sv_lowedict_threshold");
	cvarLowedictAction = FindConVar("sv_lowedict_action");
	cvarEdictLimit.AddChangeHook(OnConVarChanged);
	cvarEdictWarnLimit.AddChangeHook(OnConVarChanged);
	cvarEdictAction.AddChangeHook(OnConVarChanged);
	cvarEdictReserve.AddChangeHook(OnConVarChanged);
	OnConVarChanged(cvarEdictLimit,"","");
	OnConVarChanged(cvarEdictWarnLimit,"","");
	OnConVarChanged(cvarEdictAction,"","");
	OnConVarChanged(cvarEdictReserve,"","");
	bin = new ArrayList();
	stale = new ArrayList();
	
	HookEvent("teamplay_round_start", OnRoundStart, EventHookMode_Post);
	//HookEvent("teamplay_waiting_begins", OnRoundWaitingChange, EventHookMode_Post);
	//HookEvent("teamplay_waiting_ends", OnRoundWaitingChange, EventHookMode_Post);
	HookEvent("teamplay_round_active", OnRoundActivate, EventHookMode_Post);
	HookEvent("arena_round_start", OnRoundActivate, EventHookMode_Post);
	
	RegAdminCmd("seop_info", CmdSeopInfo, ADMFLAG_GENERIC, "Get detailed edict info");
	RegAdminCmd("seop_track", CmdSeopTrack, ADMFLAG_GENERIC, "Toggle edict tracking overlay for you");
}
public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar == cvarEdictLimit) {
		g_iEdictLimit = convar.IntValue;
	} else if (convar == cvarEdictWarnLimit) {
		g_iEdictLimitWarn = convar.IntValue;
	} else if (convar == cvarEdictAction) {
		if (convar.IntValue==0) g_iEdictAction = EdictAction_BlockSpawn;
		else if (convar.IntValue==1) g_iEdictAction = EdictAction_DeleteOldest;
		else if (convar.IntValue==2) g_iEdictAction = EdictAction_BlockSpawn|EdictAction_DeleteOldest;
	} else if (convar == cvarEdictReserve) {
		g_iEdictsPerPlayer = convar.IntValue;
	}
}

public void OnClientDisconnect(int client)
{
	clientShowInfo[client] = false;
}

public void OnGameFrame() {
	CountEdicts();
	
	int current = GetEdictCount();
	if (current > g_iHistoryMaxTf) g_iHistoryMaxTf = current;
	if (g_bWarned && current < g_iEdictLimitWarn-10) g_bWarned = false; //reset warned flag
	
	if (!(g_iEdictAction & EdictAction_DeleteOldest)) return;
	if (current > GetMaxEntities()-PANIC_CLEAR_THRESHOLD) {
		int ent;
		while ((ent = PopEdictBin())!=INVALID_ENT_REFERENCE) {
			AcceptEntityInput(ent, "Kill");
		}
		PrintToChatAll("[SEOP] Panic Cleared edicts!");
	} else {
		char buffer[64];
		int more = getOverLimit();
		if (more)
			PrintToServer("[SEOP] Removing %i edicts:", more);
		for(; more>0; more--) {
			int ent = PopEdictBin();
			if (ent == INVALID_ENT_REFERENCE) break;
			GetEdictClassname(ent, buffer, sizeof(buffer));
			//PrintToServer("  - %i %s", ent, buffer);
			AcceptEntityInput(ent, "Kill");
		}
	}
}

void StartTracking() {
	if (!g_bMapChange) return; //already tracking
	//PrintToServer("Start Track");
	ResetBin();
	stale.Clear();
	g_hSecondTimer = CreateTimer(1.0, TimerEverySecond, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	//map changed, try the engine counter again
	g_bEdictCounterDesync = false;
	g_bMapChange = false;
}
public void OnMapEnd() {
	//PrintToServer("EVENT MapEnd");
	g_bMapChange = true;
	KillTimer(g_hSecondTimer);
}
public Action OnRoundStart(Event event, const char[] name, bool dontBroadcast) {
	bool full_reset = event.GetBool("full_reset");
	//if (full_reset) PrintToServer("Full reset, %s", g_bMapChange?"Ignore":"POG");
	if (full_reset && !g_bMapChange) {
		OnMapEnd();
		RequestFrame(StartTracking);
	}
	return Plugin_Continue;
}
public void OnRoundActivate(Event event, const char[] name, bool dontBroadcast)
{ 
	//PrintToServer("RoundActive");
	StartTracking();
}


public void OnEntityCreated(int entity, const char[] classname) {
	if (!IsValidEdict(entity) || g_bMapChange) return;
	g_iEdictsCounted++;
	if (!IsTrackableEdict(entity, classname)) return;
	RequestFrame(HandleEntitySpawn, EntIndexToEntRef(entity));
}
void HandleEntitySpawn(int ref) {
	int entity = EntRefToEntIndex(ref);
	if (entity == INVALID_ENT_REFERENCE || g_bMapChange) return;
	
	int overlimit = getOverLimit();
	if (overlimit>0 && (g_iEdictAction & EdictAction_BlockSpawn)) {
		char buffer[64];
		GetEdictClassname(entity, buffer, sizeof(buffer));
		PrintToServer("[SEOP] Not spawning edict %s (%i over limit)", buffer, overlimit);
		AcceptEntityInput(entity, "Kill");
	} else {
		PushEdictBin(entity);
	}
	
	if (g_iEdictLimitWarn>0 && GetEdictCount() > g_iEdictLimitWarn && !g_bWarned) {
		g_bWarned = true;
		PrintToChatAll("The entity limit is almost reached, please slow down");
	}
}

public void OnEntityDestroyed(int entity) {
	if (!IsValidEdict(entity) || g_bMapChange) return;
	int at = bin.FindValue(SafeToEntRef(entity));
	if (at>=0) bin.Erase(at);
	stale.Push(GetGameTime());
}

public Action TimerEverySecond(Handle timer) {
	TimerHistoryUpdate();
	TimerWarnPerformance();
	TimerCheckStale();
	return Plugin_Continue;
}
public void TimerHistoryUpdate() {
	g_iHistoryAt[g_iHistoryWrite] = g_iHistoryMaxTf;
	g_iHistoryWrite = (g_iHistoryWrite+1)%HISTORY_SIZE;
	g_iHistoryMaxTf = 0;
}
public void TimerWarnPerformance() {
	//prepare the numbers
	int edicts = GetEdictCount();
	int dynLimit = g_iMapLimit + PLAYER_EDICTS;
	int gameLimit = GetMaxEntities();
	if (cvarLowedictAction.IntValue >= 2) {
		gameLimit -= cvarLowedictThreshold.IntValue;
	}
	//prepare hud text
	bool auto = edicts > g_iEdictLimitWarn; //are we close to the limit, so we ignore client prefs?
	if (edicts < g_iEdictLimitWarn) {
		SetHudTextParams(1.0, 0.1, 1.0, 255, 255, 255, 255);
	} else {
		int span = math_max( g_iEdictLimit-g_iEdictLimitWarn, 1 );
		int g = RoundToFloor((float(getEffectiveEdictLimit()-edicts) / span) * 255.0);
		if (g < 0) g = 0; else if (g > 255) g = 255;
		SetHudTextParams(1.0, 0.1, 1.0, 255, g, 0, 255);
	}
	//prepare for permission filter
	int flagBits=0;
	if (auto) {
		char flags[4];
		cvarEdictWarnOverlay.GetString(flags,sizeof(flags));
		if (strlen(flags) != 1) {
			flagBits = 0;
		} else if (flags[0]=='*') {
			flagBits = -1;
		} else {
			flagBits = ReadFlagString(flags);
		}
	}
	
	for (int client = 1; client <= MaxClients; client += 1) {
		if (!IsClientInGame(client) || !IsClientAuthorized(client)) continue;
		if (clientShowInfo[client] || flagBits<0 || (flagBits>0 && (GetUserFlagBits(client) & flagBits)!=0)) {
			ShowHudText(client, -1, "Edict Count (Plugin/Game/Stale): %i / %i / %i%s \nEdict Limit (Dyn/Plugin/Game): %i / %i / %i ",
			g_iEdictsCounted, GetEntityCount(), stale.Length, g_bEdictCounterDesync?" DS!":"", dynLimit, g_iEdictLimit, gameLimit);
		}
	}
}
void TimerCheckStale() {
	float now = GetGameTime();
	for (int i=stale.Length-1; i >= 0; i--) {
		float time = stale.Get(i);
		if ((now - time) > ENTITY_STALE_TIME)
			stale.Erase(i);
	}
}

/// the amount of edicts we should not exceed
static int getEffectiveEdictLimit() {
	//try to guess the minimum required edicts to be able to play
	int baseLimit = g_iMapLimit + PLAYER_EDICTS;
	int effectiveLimit = baseLimit > g_iEdictLimit ? baseLimit : g_iEdictLimit;
	int maxEntities = GetMaxEntities()-1;
	if (effectiveLimit > maxEntities) effectiveLimit = maxEntities;
	return effectiveLimit;
}
/// by how many edicts we should panic
static int getOverLimit() {
	int edicts = GetEdictCount();
	int overlimit = edicts - getEffectiveEdictLimit();
//	PrintToServer("Edicts currently: %i/%i, map %i, base %i, cvar %i, %i over", GetEntityCount(), effectiveLimit, g_iMapLimit, baseLimit, g_iEdictLimit, overlimit);
	return overlimit > 0 ? overlimit : 0;
}
static void ResetBin() {
	bin.Clear();
	RequestFrame(CountMapEdicts);
}
static void PushEdictBin(int entity) {
	if (!IsValidEdict(entity)) ThrowError("Will only handle edicts");
	bin.Push(SafeToEntRef(entity));
}
static int PopEdictBin() {
	int entity;
	for(int fuse; fuse<100 && bin.Length; fuse++) {
		entity = bin.Get(0);
		bin.Erase(0);
		if (IsValidEdict(entity))
			return entity;
	}
	return INVALID_ENT_REFERENCE;
}
public void CountMapEdicts(any data) {
	g_iMapLimit = GetEntityCount()+50; //some buffer
	if (g_iMapLimit > 2044) g_iMapLimit = 2044;//count is just wrong.
}
stock int SafeToEntRef(int index) {
	if (0 <= index < 4096) return EntIndexToEntRef(index);
	return index;
}
stock int SafeToEntIndex(int ref) {
	if (0 <= ref < 4096) return ref;
	return EntRefToEntIndex(ref);
}
/// count edicts into our own global once a tick
static int CountEdicts() {
	int count = MaxClients+1; //clients and world
	for (int edict = getEffectiveEdictLimit(); edict > MaxClients; edict -=1 ) {
		if (IsValidEdict(edict)||IsValidEntity(edict)) count += 1;
	}
	return (g_iEdictsCounted = (count + stale.Length));
}
/// get counted edicts and compare agains engine counter
static int GetEdictCount() {
	int edictCountEngine = GetEntityCount();
	int deviation = edictCountEngine - g_iEdictsCounted;
	if (deviation < 0) deviation = -deviation;
	
	if (g_bEdictCounterDesync) {
		if (deviation == 0) g_bEdictCounterDesync = false;
		else return g_iEdictsCounted;
	}
	if (edictCountEngine < 1 || edictCountEngine > GetMaxEntities() || deviation > 100) {
		//edict count desynced far too much, use our counter
		g_bEdictCounterDesync = true;
		return g_iEdictsCounted;
	} else {
		return math_max(g_iEdictsCounted, GetEntityCount());
	}
}

static bool IsTrackableEdict(int index, const char[] name) {
	if (index <= MaxClients) return false;
	return (strncmp(name, "ha", 2) == 0) || //halloween stuff
	       ((strncmp(name, "it", 2) == 0) && //items
	        (name[5]=='c' || name[5]=='b' || // bonuspack or currency
	         (name[5]=='h' && name[11]=='a') // healthammokit
	        )
	       ) ||
	       (strncmp(name, "ins", 3) == 0) || //instance scripted scene
	       ((strncmp(name, "tf", 2) == 0) &&
	        (name[3] == 'a' || (name[3]=='b' && name[5]=='n') || //ammo packs and bonus ducks
	         name[3] == 'd' || (name[3]=='w' && name[6]=='r') || // dropped weapons and wearables
	         (name[3] == 'z' && name[9] == 0) || //skeletons
	         (name[3] == 'p' && name[4] == 'r' && name[14] != 'g') || //projectiles, not the grapplinghook
	         (name[3] == 'r' && name[4] == 'a') //ragdolls
	        )
	       ) ||
	       ((strncmp(name, "ent", 3) == 0) && name[7] == 'r' && name[8] == 'e') || //revive marker
	       ((strncmp(name, "pr", 2) == 0) && (name[5] == 's' || name[5] == 'p' || name[6] == 'y' || name[5] == 'r')) || //ragdolls and props
	       ((strncmp(name, "fu", 2) == 0) && name[7] == 'y') //func physbox
	;
	//if (StrEqual(name, "halloween_souls_pack")) return true;
	//if (StrEqual(name, "item_bonuspack")) return true;
	//if (StrEqual(name, "item_healthammokit")) return true;
	//if (StrContains(name, "item_c")==0) return true;
	//if (StrEqual(name, "tf_ammo_pack")) return true;
	//if (StrEqual(name, "tf_bonus_duck_pickup")) return true;
	//if (StrEqual(name, "tf_dropped_weapon")) return true;
	
	//if (StrEqual(name, "tf_ragdoll")) return true;
	//if (StrContains(name, "tf_projectile_")==0 &&
	//	!StrEqual(name, "tf_projectile_grapplinghook")) return true;
	//if (StrEqual(name, "tf_zombie")) return true;
	//if (StrEqual(name, "entity_revive_marker")) return true;
	//if (StrEqual(name, "instanced_scripted_scene")) return true; //responsible for mimic and animation overlays
	//if (StrEqual(name, "tf_wearable")) return true; //cosmetics
	
	//if (StrContains(name, "prop_physics")==0) return true;
	//if (StrContains(name, "prop_static")==0) return true;
	//if (StrContains(name, "prop_dynamic")==0) return true;
	//if (StrContains(name, "func_physbox")==0) return true;
	//return false;
}

public Action CmdSeopInfo(int client, int args) {
	int reserved = PLAYER_EDICTS;
	int effectiveLimit = getEffectiveEdictLimit();
	int edicts = GetEdictCount();
	
	int min=0x7fffffff,max=0,read;
	for (int i;i<HISTORY_SIZE;i++) {
		if (g_iHistoryAt[i]<min) min = g_iHistoryAt[i];
		if (g_iHistoryAt[i]>max) max = g_iHistoryAt[i];
	}
	int span = max-min;
	if (span == 0) span = 1;
	char stringified[HISTORY_SIZE+1];
	for (int i;i<HISTORY_SIZE;i++) {
		read = (g_iHistoryWrite+i)%HISTORY_SIZE;
		stringified[i] = '0'+RoundFloat(9.0 * float(g_iHistoryAt[read]-min) / float(span) );
	}
	if (client) {
		PrintToConsole(client, "Edict Limits:   %i + %i / %i (map, reserved, cvar)", g_iMapLimit, reserved, g_iEdictLimit);
		PrintToConsole(client, "Current Edicts: %i / %i / %i + %i (count, limit, tracked, stale)", edicts, effectiveLimit, bin.Length, stale.Length);
		PrintToConsole(client, "Last minute: %i - %i", min, max);
		PrintToConsole(client, "   %s", stringified);
	} else {
		PrintToServer("Edict Limits:   %i + %i / %i (map, reserved, cvar)", g_iMapLimit, reserved, g_iEdictLimit);
		PrintToServer("Current Edicts: %i / %i / %i + %i (count, limit, tracked, stale)", edicts, effectiveLimit, bin.Length, stale.Length);
		PrintToServer("Last minute: %i - %i", min, max);
		PrintToServer("   %s", stringified);
	}
	return Plugin_Handled;
}

public Action CmdSeopTrack(int client, int args) {
	if (!client) {
		ReplyToCommand(client, "This is a client command");
	} else {
		clientShowInfo[client] = !clientShowInfo[client];
		PrintToChat(client, "[SEOP] Overlay %s", (clientShowInfo[client]?"enabled":"disabled"));
	}
	return Plugin_Handled;
}

static int math_max(int a, int b) {
	return a>b?a:b;
}