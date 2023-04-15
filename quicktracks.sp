#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <smlib>
#include <tf2>
#include <tf2_stocks>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "22w44a"

public Plugin myinfo = {
	name = "Quick Tracks",
	description = "Set up some simple race tracks for events",
	author = "reBane",
	version = PLUGIN_VERSION,
	url = "N/A",
};

#define ZONE_NOTSTARTED -1
#define ZONE_INSTART -2
#define ZONE_EDITNONE -1
#define INVALID_TRACK -1
#define EDIT_NONE 0
#define EDIT_TRACK 1
#define EDIT_ZONE 2
#define EDIT_TRACKSUB 3

#define RULE_CLASS(%1) (1<<(%1))
#define RULE_ALLCLASSES (0x01FF)
#define RULE_NOCHARGE (1<<9)
#define RULE_TAUNTONLY (1<<10)
#define RULE_VEHICLEONLY (1<<11)
#define RULE_DONTJUMP (1<<12)
#define RULE_DONTLAND (1<<13)

#define MAX_ZONES_PER_TRACK 64
//one vgui menu page can hold 7, usual player cap is ~32
#define MAX_TRACK_SCORES 35

// a timers minimal interval is 0.1 seconds, so playersPerTick/maxPlayerCount should be > 0.1
// if you have more players (other game), adjust SPLIT_TIMER_FOR_PLAYERS
// if you come out to more than 1 player/tick, change TIMER_PLAYERS_PER_TICK
#define SPLIT_TIMER_FOR_PLAYERS 32
#define TIMER_PLAYERS_PER_TICK 4

float ZERO_VECTOR[3];

//TFClassType gMenuClass[9] = {
//	TFClass_Scout, TFClass_Soldier, TFClass_Pyro, TFClass_DemoMan, TFClass_Heavy, TFClass_Engineer, TFClass_Medic, TFClass_Sniper, TFClass_Spy
//};
char gMenuClassNames[9][12] = {
	"Scout", "Soldier", "Pyro", "Demoman", "Heavy", "Engineer", "Medic", "Sniper", "Spy"
};
int gMenuClassReverse[10] = {
	-1, 0, 7, 1, 3, 6, 4, 2, 8, 5
};

enum struct ZoneData {
	int track;
	float mins[3];
	float maxs[3];
	
	bool IsInside(int entity) {
		float vec[3];
		Entity_GetAbsOrigin(entity, vec);
		vec[2] += 1.0; //make "inside" on the ground more reliable
		for (int i=0;i<3;i++) {
			if (vec[i] < this.mins[i] || vec[i] > this.maxs[i]) return false;
		}
		return true;
	}
	void Bring(int entity) {
		float pos[3];
		this.GetTelepoint(pos);
		TeleportEntity(entity, pos, NULL_VECTOR, ZERO_VECTOR);
	}
	void GetTelepoint(float vec[3]) {
		AddVectors(this.mins, this.maxs, vec);
		ScaleVector(vec, 0.5);
		vec[2] = this.mins[2]+24; //don't tp floating
	}
}

enum struct Attempt {
	int track;
	int lap;
	int zone;
	float time;
	
	void Init(int track) {
		this.track = track;
		this.lap = 0;
		this.time = 0.0;
		this.zone = (track == INVALID_TRACK) ? ZONE_NOTSTARTED : ZONE_INSTART;
	}
}

enum struct ScoreData {
	float time; //sort by
	int track;
	char steamid[48];
}

ArrayList g_Tracks;
Attempt clientAttempts[MAXPLAYERS+1];
int clientEditorState[MAXPLAYERS+1];
int clientTrackEditIndex[MAXPLAYERS+1];
int clientZoneEditIndex[MAXPLAYERS+1];
int clientVehicleTaunting[MAXPLAYERS+1];
bool clientIsAirborn[MAXPLAYERS+1];

StringMap g_authNames;
char clientSteamIds[MAXPLAYERS+1][48];

int g_iLaserBeam;

ArrayList g_TrackScores;

enum struct Track {
	char name[64];
	ArrayList zones; //list of zonedata
	bool open;
	int laps; //0 for linear
	int rules;
	
	void Reinit(int selfTrack) {
		if (selfTrack >= 0 && this.zones != null) this.zones.Clear();
		else this.zones = new ArrayList(sizeof(ZoneData));
		this.rules = RULE_ALLCLASSES;
	}
	void Free(int selfTrack) {
		if (this.zones != null) delete this.zones;
		if (selfTrack >= 0) {
			g_Tracks.Erase(selfTrack);
			// for everything refing a track > selfTrack, decrement track index
			for (int client = 1; client <= MaxClients; client += 1) {
				if (clientAttempts[client].track > selfTrack) clientAttempts[client].track -= 1;
				if (clientTrackEditIndex[client] > selfTrack) clientTrackEditIndex[client] -= 1;
				//scores
			}
		}
	}
	
	int PushSelf(int selfTrack=-1) {
		if (selfTrack>=0 && selfTrack<g_Tracks.Length) {
			g_Tracks.SetArray(selfTrack, this);
			return selfTrack;
		} else
			return g_Tracks.PushArray(this);
	}
	void FetchSelf(int selfTrack) {
		g_Tracks.GetArray(selfTrack, this);
	}
}

int Track_FindByClientStart(int client) {
	Track track;
	ZoneData zone;
	for (int t=g_Tracks.Length-1; t>=0; t-=1) {
		if (Track_IsInEditor(t)) continue;
		track.FetchSelf(t);
		if (!track.open || track.zones.Length==0) continue;
		track.zones.GetArray(0, zone);
		if (zone.IsInside(client)) {
			return t;
		}
	}
	return INVALID_TRACK;
}
int Track_FindByName(const char[] name) {
	Track track;
	for (int t=g_Tracks.Length-1; t>=0; t-=1) {
		track.FetchSelf(t);
		if (StrEqual(track.name, name, false)) {
			return t;
		}
	}
	return INVALID_TRACK;
}
int Track_IsInEditor(int track) {
	for (int i=1; i<=MaxClients; i++) {
		if (clientEditorState[i] != EDIT_NONE && clientTrackEditIndex[i] == track) return i;
	}
	return 0;
}
void Track_StartEditFrame(DataPack pack) {
	//unpack args and retry, in case a menu was open
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int track = pack.ReadCell();
	delete pack;
	if (!client || track >= g_Tracks.Length || track < 0) return;
	Track_StartEdit(client,track);
}
void Track_StartEdit(int client, int track) {
	if (clientEditorState[client] != EDIT_NONE || clientTrackEditIndex[client] != INVALID_TRACK) {
		//the editor is still open
		//cancelling the menu will clear some values, we dont want that in this case
		if (!CancelClientMenu(client)) {
			//there was a problem with the menu, reset editor and open
			clientEditorState[client] = EDIT_TRACK;
			clientTrackEditIndex[client] = track;
			clientZoneEditIndex[client] = ZONE_EDITNONE;
			ShowEditTrackMenu(client);
		} else {
			//wait for the menu to process the cancel, collect args to retry later
			DataPack pack = new DataPack();
			pack.WriteCell(GetClientUserId(client));
			pack.WriteCell(track);
			RequestFrame(Track_StartEditFrame, pack);
		}
	} else {
		clientEditorState[client] = EDIT_TRACK;
		clientTrackEditIndex[client] = track;
		clientZoneEditIndex[client] = ZONE_EDITNONE;
		ShowEditTrackMenu(client);
	}
}

bool Track_CheckClientRules(int client, int trackIdx) {
	Track track;
	track.FetchSelf(trackIdx);
	int playerClass = gMenuClassReverse[TF2_GetPlayerClass(client)];
	if (playerClass < 0) {
		Attempt_Stop(client);
		return false;
	}
	if (!(track.rules & RULE_CLASS(playerClass))) {
		PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled: The class %s is not allowed", track.name, gMenuClassNames[playerClass]);
		Attempt_Stop(client);
		return false;
	}
	if (track.rules & RULE_DONTJUMP && GetClientButtons(client) & IN_JUMP) {
		PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled: Do not jump", track.name);
		Attempt_Stop(client);
		return false;
	}
	if (track.rules & RULE_DONTLAND) {
		bool ground = !!(GetEntityFlags(client) & (FL_SWIM|FL_FROZEN|FL_INWATER|FL_ONGROUND|FL_PARTIALGROUND));
		if (clientIsAirborn[client] && ground) {
			PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled: Do not land after leaving the ground", track.name);
			Attempt_Stop(client);
			return false;
		}
		clientIsAirborn[client]=!ground;
	}
	if ((track.rules & RULE_VEHICLEONLY)) {
		if (!clientVehicleTaunting[client]) {
			PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled: Track requires vehicle taunt", track.name);
			Attempt_Stop(client);
			return false;
		} 
		return true;
	}
	if ((track.rules & RULE_NOCHARGE) && TF2_IsPlayerInCondition(client, TFCond_Charging)) {
		PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled: Charging is not allowed", track.name);
		Attempt_Stop(client);
		return false;
	}
	if ((track.rules & RULE_TAUNTONLY) && !TF2_IsPlayerInCondition(client, TFCond_Taunting)) {
		PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled: Track requires taunting", track.name);
		Attempt_Stop(client);
		return false;
	}
	return true;
}

#define SELF clientAttempts[client]
int Attempt_GetClientZone(int client) {
	if (SELF.track == INVALID_TRACK || SELF.zone == ZONE_NOTSTARTED) return ZONE_NOTSTARTED;
	
	Track track;
	track.FetchSelf(SELF.track);
	if (!track.open || track.zones.Length <= 1) return ZONE_NOTSTARTED; //track not yet valid
	
	ZoneData zone;
	if (SELF.zone == ZONE_INSTART && track.zones.GetArray(0,zone) && !zone.IsInside(client)) {
		//timer is paused in start zone, we just left, so go
		_OnClientAdvanceTrack(client, SELF.zone = 0, track.zones.Length, SELF.lap = (track.laps?1:0), track.laps);
		return 0;
	}
	if (SELF.zone >= 0) {
		//checkpoint handling
		for (int i=track.zones.Length-1; i>=0; i--) {
			track.zones.GetArray(i,zone);
			if (!zone.IsInside(client)) continue;
			if (i == 0) {
				if (!track.laps || (SELF.lap <= 1 && SELF.zone < 1)) {
					//if we are in the start zone, revert to pre-attempt
					// reset only if linear, or no checkpoint was passed yet
					return (SELF.zone = ZONE_INSTART);
				} else if (SELF.zone == track.zones.Length-1) {
					//previously visited the last zone, now touching the first
					_OnClientAdvanceTrack(client, SELF.zone = 0, track.zones.Length, SELF.lap += 1, track.laps);
					if (SELF.zone == ZONE_NOTSTARTED) break; //we just finished
				}
			} 
			if (i == SELF.zone + 1) {
				_OnClientAdvanceTrack(client, SELF.zone = i, track.zones.Length, SELF.lap, track.laps);
				return i;
			}
		}
	}
	return SELF.zone;
}
void Attempt_Stop(int client) {
	SELF.track = INVALID_TRACK;
	SELF.zone = ZONE_NOTSTARTED;
	SELF.lap = 0;
}
#undef SELF

public void OnClientConnected(int client) {
	OnClientDisconnect(client);
}
public void OnClientDisconnect(int client) {
	clientAttempts[client].Init(INVALID_TRACK);
	clientSteamIds[client] = "";
	clientEditorState[client] = EDIT_NONE;
	clientTrackEditIndex[client] = INVALID_TRACK;
	clientZoneEditIndex[client] = ZONE_EDITNONE;
}
public void OnClientAuthorized(int client, const char[] auth) {
	if (!GetClientAuthId(client, AuthId_Steam2, clientSteamIds[client], sizeof(clientSteamIds[]))) {
		ThrowError("Could not read SteamID for client %i (%N)", client, client);
	}
	char buffer[48];
	GetClientName(client, buffer, sizeof(buffer));
	g_authNames.SetString(clientSteamIds[client], buffer);
}

public void TF2_OnConditionAdded(int client, TFCond condition) {
	if (condition == TFCond_Taunting) {
		int taunt = GetEntProp(client, Prop_Send, "m_iTauntItemDefIndex");
		PrintToServer("Client %N is playing taunt %i", client, taunt);
		switch (taunt) {
			case 31156, //boston boarder
			     30920, //bunnyhopper
			     1197, //scooty scoot
			     1196, //panzer pants
			     31155, //rocket jockey
			     31239, //hot wheeler
			     30919, //skating scorcher
			     30840, //scotsmann's stagger
			     30845, //jumping jack
			     31160, //texas truckin
			     31203, //mannbulance
			     1172, //victory lap
			     30672, //zoomin' broom
			     31290, //travel agent 
			     31291, //drunk man's cannon
			     31292: //shanty shipmate
			{
				clientVehicleTaunting[client] = true;
			}
			default: {
				clientVehicleTaunting[client] = false;
			}
		}
	}
}
public void TF2_OnConditionRemoved(int client, TFCond condition) {
	if (condition == TFCond_Taunting) {
		clientVehicleTaunting[client] = false;
	}
}


void _OnClientStartTrack(int client, int trackIdx) {
	clientAttempts[client].Init(trackIdx);
	Track track;
	track.FetchSelf(trackIdx);
	PrintToChat(client, "[QT] You have started the track \"%s\".\n  Use /stoptrack to cancel.", track.name);
	if (track.rules != RULE_ALLCLASSES) {
		char buffer[256];
		//non-default rules, let's tell the player
		if ((track.rules & RULE_ALLCLASSES) != RULE_ALLCLASSES) {
			//class limits are imposed
			buffer = "  These classes are blocked: ";
			for (int class; class < 9; class++) {
				if (!(track.rules & RULE_CLASS(class))) {
					Format(buffer, sizeof(buffer), "%s%s, ", buffer, gMenuClassNames[class]);
				}
			}
			buffer[strlen(buffer)-2]=0; //remove last comma
			PrintToChat(client, buffer);
		}
		if ((track.rules & ~RULE_ALLCLASSES)) {
			//other rules are imposed
			buffer = "  This track requires: ";
			if ((track.rules & RULE_NOCHARGE)) StrCat(buffer, sizeof(buffer), "No Demo Charging, ");
			if ((track.rules & RULE_TAUNTONLY)) StrCat(buffer, sizeof(buffer), "Taunting Only, ");
			if ((track.rules & RULE_VEHICLEONLY)) StrCat(buffer, sizeof(buffer), "Vehicle Taunt, ");
			if ((track.rules & RULE_DONTJUMP)) StrCat(buffer, sizeof(buffer), "Don't Jump, ");
			if ((track.rules & RULE_DONTLAND)) StrCat(buffer, sizeof(buffer), "Don't Land, ");
			buffer[strlen(buffer)-2]=0; //remove last comma
			PrintToChat(client, buffer);
		}
	}
}

void _OnClientAdvanceTrack(int client, int zone, int zoneCount, int lap, int lapCount) {
	//zones start at 0, laps start at 1
	if (lapCount) {
		if (zone == 0 && lap == 1) {
			clientAttempts[client].time = GetClientTime(client);
			PrintHintText(client, "[QuickTrack] Info\nLap: %i/%i\nZone: -/%i\nTime: -.--s", lap,lapCount, zoneCount-1);
		} else if (zone == 0 && lap > lapCount) {
			clientAttempts[client].time = GetClientTime(client) - clientAttempts[client].time;
			PrintHintText(client, "[QuickTrack] Info\nFINISH\n \nTime: %.2fs", clientAttempts[client].time);
			_OnClientTrackFinish(client);
		} else {
			PrintHintText(client, "[QuickTrack] Info\nLap: %i/%i\nZone: %i/%i\nTime: %.2fs", lap,lapCount, zone,zoneCount-1, GetClientTime(client)-clientAttempts[client].time);
		}
	} else {
		if (zone == 0) {
			clientAttempts[client].time = GetClientTime(client);
			PrintHintText(client, "[QuickTrack] Info\nLinear\nZone: -/%i\nTime: -.--s", zoneCount-1);
		} else if (zone+1 == zoneCount) {
			clientAttempts[client].time = GetClientTime(client) - clientAttempts[client].time;
			PrintHintText(client, "[QuickTrack] Info\nFINISH\n \nTime: %.2fs", clientAttempts[client].time);
			_OnClientTrackFinish(client);
		} else {
			PrintHintText(client, "[QuickTrack] Info\nLinear\nZone: %i/%i\nTime: %.2fs", zone,zoneCount-1, GetClientTime(client)-clientAttempts[client].time);
		}
	}
}

int ScoreGetTrackTop(int track, int start=-1) {
	for (int i=start+1; i<g_TrackScores.Length; i+=1) {
		if (g_TrackScores.Get(i, ScoreData::track) == track)
			return i;
	}
	return -1;
}
int ScoreGetInsertIndex(float time, int start=-1) {
	for (int i=start+1; i<g_TrackScores.Length; i+=1) {
		if (view_as<float>(g_TrackScores.Get(i, ScoreData::time)) > time)
			return i;
	}
	return -1;
}
int ScoreGetIndexTrack(int track, int client) {
	for (int i=0; i<g_TrackScores.Length; i+=1) {
		ScoreData score;
		g_TrackScores.GetArray(i,score);
		if (score.track == track && StrEqual(score.steamid, clientSteamIds[client])) {
			return i;
		}
	}
	return -1;
}

void _OnClientTrackFinish(int client) {
	Track track;
	int trackid = clientAttempts[client].track;
	track.FetchSelf(trackid);
	
	ScoreData score;
	score.time = clientAttempts[client].time;
	score.track = trackid;
	strcopy(score.steamid, sizeof(ScoreData::steamid), clientSteamIds[client]);
	
	//get previous time
	int prevAt = ScoreGetIndexTrack(clientAttempts[client].track, client);
	float prevTime = prevAt >= 0 ? g_TrackScores.Get(prevAt, ScoreData::time) : -1.0;
	//   we had no previous pb (within MAX_TRACK_SCORES) or improved
	bool newPB = prevAt < 0 || score.time < prevTime;
	if (prevAt >= 0 && newPB) g_TrackScores.Erase(prevAt); //we improved our time, drop the old one
	int insertAt = ScoreGetInsertIndex(clientAttempts[client].time);
	//get top time and num scores
	int results; //number of scores for this track
	int search=-1; //will be the last score index after counting (-1 for none yet)
	int firstIndex=-1; //best score for the track (-1 for none yet)
	while (results < MAX_TRACK_SCORES) {
		int at = ScoreGetTrackTop(trackid, search);
		if (at < 0) break;
		if (firstIndex < 0) firstIndex = at;
		results += 1;
		search = at;
	}
	//   no scores yet, or we insert a time ahead of all others
	bool newWR = firstIndex == -1 || (insertAt >= 0 && insertAt <= firstIndex);
	//   we have to drop a score, if MAX_TRACK_SCORES are exhausted and we instert our score
	bool dropLast = results >= MAX_TRACK_SCORES && insertAt >= 0 && insertAt <= search;
	//   do not insert, if our score would be after the worst score and we have MAX_TRACK_SCORES
	//   so insert if we have a better score or there's still room for worse scores.
	//   if we insert post, or no times are yet set, the second clause in the || will pass.
	//   also, even if there's room for worse scores, we only want to track 1 per player
	//   so insert only if we dropped the old score (new pb) or didn't have a previous score.
	bool insert = ((insertAt >= 0 && insertAt <= search) || results < MAX_TRACK_SCORES) && newPB;
	
	//actual insert logic
	if (insert) {
		if (dropLast) {
			//this score will push an old one out the bottom (search is last result at this point)
			g_TrackScores.Erase(search);
		}
		if (insertAt >= 0 && insertAt < g_TrackScores.Length) {
			//we actually insert in the middle
			g_TrackScores.ShiftUp(insertAt);
			g_TrackScores.SetArray(insertAt, score);
		} else {
			//we append at the end
			insertAt = g_TrackScores.PushArray(score);
		}
	}
	if (newWR) {
		PrintToChatAll("\x01\x07c816ff[QT] \x01%N\x07ffc800 got 1st place in \x01\"%s\" \x07ffc800with \x073298ff%.2fs", client, track.name, clientAttempts[client].time);
		
		char soundFile[128];
		Format(soundFile, sizeof(soundFile), "ambient_mp3/bumper_car_cheer%i.mp3", GetRandomInt(1,3));
		EmitSoundToAll(soundFile);
	} else if (newPB) {
		if (prevAt==-1)
			PrintToChatAll("\x01\x07c816ff[QT] \x01%N\x04 completed \x01\"%s\" \x04in \x05%.2fs", client, track.name, clientAttempts[client].time);
		else
			PrintToChatAll("\x01\x07c816ff[QT] \x01%N\x04 completed \x01\"%s\" \x04in \x05%.2fs \x03(%.2fs)", client, track.name, clientAttempts[client].time, clientAttempts[client].time-prevTime);
	} else {
		PrintToChat(client, "\x01\x07c816ff[QT] \x04You completed \x01\"%s\" \x04in \x05%.2fs", track.name, clientAttempts[client].time);
	}
	Attempt_Stop(client);
}

public void OnPluginStart() {
	g_Tracks = new ArrayList(sizeof(Track));
	g_authNames = new StringMap();
	g_TrackScores = new ArrayList(sizeof(ScoreData));
	
	RegAdminCmd("sm_edittrack", Command_MakeTrack, ADMFLAG_GENERIC, "Usage: <TrackName> - Create or edit a track", "quicktracks");
	RegConsoleCmd("sm_stoptrack", Command_StopTrack, "Stop a track without finishing it");
	RegConsoleCmd("sm_tracktop", Command_TrackTop, "Usage: [TrackName] - Display top times for the track you're in or the named track");
	AddCommandListener(Command_TeamSay, "say_team");
	
	HookEvent("player_changename", OnPlayerChangeName);
	HookEvent("player_teleported", OnPlayerTeleported, EventHookMode_Pre);
	HookEvent("player_death", OnPlayerDeath);
	
	for (int client=1; client<=MaxClients; client++) {
		if (IsClientConnected(client)) {
			OnClientConnected(client);
			if (IsClientInGame(client)) {
				HookClient(client);
			}
			if (IsClientAuthorized(client)) {
				OnClientAuthorized(client, "");
			}
		}
	}
}

public void OnMapStart() {
	g_iLaserBeam = PrecacheModel("materials/sprites/laserbeam.vmt", true);
	for (int i=1;i<=3;i++) {
		char soundFile[128];
		Format(soundFile, sizeof(soundFile), "ambient_mp3/bumper_car_cheer%i.mp3", i);
		PrecacheSound(soundFile, true);
	}
	//poke every player once a second
	CreateTimer(float(TIMER_PLAYERS_PER_TICK)/float(SPLIT_TIMER_FOR_PLAYERS), Timer_DrawZones, _, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
	LoadTracks();
}

public void OnMapEnd() {
	//stop attempts
	for (int i=1; i<=MaxClients; i+=1) {
		Attempt_Stop(i);
	}
	//every track has a handle for the tracks zones, free those!
	for (int i=g_Tracks.Length-1; i>=0; i-=1) {
		delete view_as<ArrayList>(g_Tracks.Get(i,Track::zones));
	}
	//reset tracks an scores
	g_Tracks.Clear();
	g_TrackScores.Clear();
}

public void OnPlayerChangeName(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || IsFakeClient(client)) return;
	char buffer[48];
	event.GetString("newname", buffer, sizeof(buffer));
	if (buffer[0]) {
		g_authNames.SetString(clientSteamIds[client], buffer);
	}
}

public void OnEntityCreated(int entity, const char[] classname) {
	if (StrEqual(classname, "player")) {
		HookClient(entity);
	}
}

void HookClient(int client) {
	SDKHook(client, SDKHook_OnTakeDamagePost, OnClientTakeDamagePost);
}
public void OnClientTakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype) {
	if (IsClientInGame(victim) && !IsFakeClient(victim) && GetClientHealth(victim) <= 0)
		HandleClientDeath(victim);
}
public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client && !IsFakeClient(client))
		HandleClientDeath(client);
}
void HandleClientDeath(int client) {
	if (clientAttempts[client].track != INVALID_TRACK) {
		clientVehicleTaunting[client] = false;
		clientIsAirborn[client] = false;
		Track track;
		track.FetchSelf(clientAttempts[client].track);
		PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled", track.name);
		Attempt_Stop(client);
	}
}

public Action OnPlayerTeleported(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client && clientAttempts[client].track != INVALID_TRACK) {
		Track track;
		track.FetchSelf(clientAttempts[client].track);
		PrintToChat(client, "[QT] Your attempt at \"%s\" was cancelled", track.name);
		Attempt_Stop(client);
	}
	return Plugin_Continue;
}

public void OnGameFrame() {
	for (int client=1;client<=MaxClients;client+=1) {
		if (!IsClientInGame(client) || GetClientTeam(client) < 2 || IsFakeClient(client)) continue;
		//game specific stuff (prevent scoring under some conditions)
		if (GetEngineVersion()==Engine_TF2 && TF2_IsPlayerInCondition(client, TFCond_Teleporting)) continue;
		
		int index, zone = Attempt_GetClientZone(client);
		//checking the client zone automatically advances zones/track progress
		if (zone == ZONE_NOTSTARTED) {
			index = Track_FindByClientStart(client);
			if (index > INVALID_TRACK) {
				clientIsAirborn[client] = false;
				_OnClientStartTrack(client, index);
			}
		} else if ((index = Track_IsInEditor(clientAttempts[client].track))) {
			Track track;
			track.FetchSelf(clientTrackEditIndex[index]);
			PrintToChat(client, "[QT] The track \"%s\" was moved into the editor", track.name);
			Attempt_Stop(client);
		} else if (zone >= 0) {
			Track_CheckClientRules(client, index); //not following the set up rules
		}
	}
}

public Action Command_MakeTrack(int client, int args) {
	if (args == 0) {
		if (g_Tracks.Length == 0)
			ReplyToCommand(client, "[QT] Specify a track name to create or edit a track");
		ShowTrackPickMenu(client);
		return Plugin_Handled;
	}
	char givenname[64];
	GetCmdArgString(givenname, sizeof(givenname));
	int trackid = Track_FindByName(givenname);
	if (trackid == INVALID_TRACK) {
		Track track;
		track.Reinit(INVALID_TRACK);
		strcopy(track.name, sizeof(Track::name), givenname);
		trackid = g_Tracks.PushArray(track);
	}
	int editor;
	if ((editor=Track_IsInEditor(trackid)) && editor != client) {
		ReplyToCommand(client, "[QT] %N is already editing this track", editor);
	} else {
		Track_StartEdit(client, trackid);
	}
	return Plugin_Handled;
}

public Action Command_StopTrack(int client, int args) {
	if (clientAttempts[client].track == INVALID_TRACK) {
		ReplyToCommand(client, "[QT] You're not running any track");
	} else if (clientAttempts[client].zone < 0) {
		ReplyToCommand(client, "[QT] Please leave the start zone to stop");
	} else {
		Track track;
		track.FetchSelf(clientAttempts[client].track);
		ReplyToCommand(client, "[QT] You stopped the track \"%s\"", track.name);
		Attempt_Stop(client);
	}
	return Plugin_Handled;
}

public Action Command_TrackTop(int client, int args) {
	char trackname[64];
	GetCmdArgString(trackname, sizeof(trackname));
	StripQuotes(trackname);
	int trackid;
	if ((trackid = Track_FindByName(trackname))==INVALID_TRACK) 
		trackid = clientAttempts[client].track;
	if (trackid == INVALID_TRACK) {
		ReplyToCommand(client, "[QT] You didn't specify a track and are not running any");
		return Plugin_Handled;
	}
	Track track;
	track.FetchSelf(trackid);
	Menu menu = CreateMenu(HandleTrackTopMenu);
	menu.SetTitle("Top times for track\n%s\n ",track.name);
	int at=-1;
	ScoreData score;
	int rank=1;
	for(;;) {
		at = ScoreGetTrackTop(trackid, at);
		if (at < 0) break;
		
		g_TrackScores.GetArray(at, score);
		char buffer[64];
		g_authNames.GetString(score.steamid, buffer, sizeof(buffer));
		Format(buffer, sizeof(buffer), "#%i %s [%.2fs]", rank++, buffer, score.time);
		menu.AddItem("", buffer, ITEMDRAW_DISABLED);
	}
	if (rank == 1) {
		//still wants to fill first place, so no scores
		menu.AddItem("", "No times yet", ITEMDRAW_DISABLED);
	}
	
	menu.Display(client, 60);
	return Plugin_Handled;
}

public int HandleTrackTopMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	}
	return 0;
}

public Action Command_TeamSay(int client, const char[] command, int argc) {
	//hijack team say if we are in the pick-zone state
	if (GetCmdArgs() != 1 || clientEditorState[client] != EDIT_ZONE || clientTrackEditIndex[client] == INVALID_TRACK || clientZoneEditIndex[client] != ZONE_EDITNONE) {
		return Plugin_Continue;
	}
	int value;
	char argstring[32];
	GetCmdArgString(argstring, sizeof(argstring));
	StripQuotes(argstring);
	if (StringToIntEx(argstring, value) != strlen(argstring)) {
		return Plugin_Continue;
	}
	value -= 1; //from natural counting to index
	
	Track track;
	track.FetchSelf(clientTrackEditIndex[client]);
	if (value < 0 || value >= track.zones.Length) {
		return Plugin_Continue;
	}
	
	clientZoneEditIndex[client] = value;
	ShowEditZoneMenu(client);
	return Plugin_Stop;
}

void ShowTrackPickMenu(int client) {
	if (clientEditorState[client] != EDIT_NONE) {
		PrintToChat(client, "[QT] You are currently editing a track");
		return;
	}
	Menu menu = CreateMenu(HandleTrackPickMenu);
	menu.SetTitle("Track Menu");
	menu.AddItem("save", "<Save Tracks>");
	menu.AddItem("load", "<Reload Tracks>");
	if (g_Tracks.Length) {
		char buffer[16];
		Track track;
		for (int i=0;i<g_Tracks.Length;i++) {
			Format(buffer, sizeof(buffer), "%d", i);
			g_Tracks.GetArray(i,track);
			menu.AddItem(buffer,track.name);
		}
	} else {
		menu.AddItem("--", "No tracks yet", ITEMDRAW_DISABLED);
	}
	menu.Display(client, MENU_TIME_FOREVER);
}

public int HandleTrackPickMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	} else if (action == MenuAction_Select) {
		char buffer[16], name[64];
		menu.GetItem(param2, buffer, sizeof(buffer), _, name, sizeof(name));
		if (StrEqual(buffer,"save")) {
			SaveTracks();
			PrintToChat(param1, "[QT] You saved the tracks for this map to disk");
		} else if (StrEqual(buffer,"load")) {
			OnMapEnd();
			LoadTracks();
			PrintToChat(param1, "[QT] You reloaded all tracks from disk - all changes and score were cleared");
		} else if (!StrEqual(buffer,"--")) {
			int track = Track_FindByName(name);
			if (track == INVALID_TRACK) {
				PrintToChat(param1, "[QT] Selecting track %s failed, maybe another player changed the track list", name);
			} else {
				Track_StartEdit(param1, track);
			}
		}
	}
	return 0;
}

void ShowEditTrackMenu(int client) {
	if (clientEditorState[client] != EDIT_TRACK) {
		PrintToChat(client, "[QT] You are not editing any track at the moment");
		return;
	}
	Menu menu = CreateMenu(HandleEditTrackMenu);
	char buffer[250];
	Track track;
	track.FetchSelf(clientTrackEditIndex[client]);
	menu.SetTitle("Editing Track\n %s", track.name);
	Format(buffer, sizeof(buffer), "Is Open? %c", ((track.open)?'Y':'N'));
	menu.AddItem("open", buffer);
	Format(buffer, sizeof(buffer), "%i Zones...", track.zones.Length);
	menu.AddItem("zones", buffer);
	if (track.laps) Format(buffer, sizeof(buffer), "%i Laps...", track.laps); else buffer = "Linear...";
	menu.AddItem("laps", buffer);
	menu.AddItem("rules", "Rules...");
	menu.AddItem("", "", ITEMDRAW_SPACER);
	menu.AddItem("reset", "Reset Scores");
	menu.AddItem("", "", ITEMDRAW_SPACER);
	menu.AddItem("delete", "Delete Track");
	
	menu.Pagination = MENU_NO_PAGINATION;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int HandleEditTrackMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	} else if (action == MenuAction_Cancel) {
		if (param2 != MenuCancel_Interrupted || (clientEditorState[param1] != EDIT_ZONE && clientEditorState[param1] != EDIT_TRACKSUB) ) {
			//menu went away by exit, disconnect, ... OR was interruped by something other than the zone edit menu or another sub menu
			clientEditorState[param1] = EDIT_NONE;
			clientTrackEditIndex[param1] = INVALID_TRACK;
		}
	} else if (action == MenuAction_Select) {
		Track track;
		char info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		if (StrEqual(info, "open")) {
			track.FetchSelf(clientTrackEditIndex[param1]);
			track.open =! track.open;
			track.PushSelf(clientTrackEditIndex[param1]);
			ShowEditTrackMenu(param1);
		} else if (StrEqual(info, "zones")) {
			clientEditorState[param1] = EDIT_ZONE;
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "laps")) {
			clientEditorState[param1] = EDIT_TRACKSUB;
			ShowEditLapsMenu(param1);
		} else if (StrEqual(info, "rules")) {
			clientEditorState[param1] = EDIT_TRACKSUB;
			ShowEditRulesMenu(param1);
		} else if (StrEqual(info, "reset")) {
			//delete scores for track
			for (int i=g_TrackScores.Length-1; i>=0; i-=1) {
				if (g_TrackScores.Get(i, ScoreData::track) == clientTrackEditIndex[param1]) {
					g_TrackScores.Erase(i);
				}
			}
			PrintToChat(param1, "[QT] Scores for this track were cleared");
			ShowEditTrackMenu(param1);
		} else if (StrEqual(info, "delete")) {
			//delete scores for this track
			for (int i=g_TrackScores.Length-1; i>=0; i-=1) {
				if (g_TrackScores.Get(i, ScoreData::track) == clientTrackEditIndex[param1]) {
					g_TrackScores.Erase(i);
				}
			}
			//delete the track itself
			track.FetchSelf(clientTrackEditIndex[param1]);
			track.Free(clientTrackEditIndex[param1]);
			clientEditorState[param1] = EDIT_NONE;
			clientTrackEditIndex[param1] = INVALID_TRACK;
			PrintToChat(param1, "[QT] The track \"%s\" was deleted!", track.name);
		}
	}
	return 0;
}

void ShowEditZoneMenu(int client) {
	if (clientEditorState[client] != EDIT_ZONE) {
		PrintToChat(client, "[QT] You are not editing any zone at the moment");
		return;
	}
	if (clientZoneEditIndex[client] == ZONE_EDITNONE) {
		ShowPickZoneMenu(client);
		return;
	}
	Menu menu = CreateMenu(HandleEditZoneMenu);
	Track track;
	track.FetchSelf(clientTrackEditIndex[client]);
	menu.SetTitle("Editing Track\n %s\n Zone %i", track.name, clientZoneEditIndex[client]+1); //display natural index
	menu.AddItem("mins", "Set low bounds");
	menu.AddItem("maxs", "Set high bounds");
	menu.AddItem("prev", "Previous zone", clientZoneEditIndex[client] > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("next", "Next zone", clientZoneEditIndex[client]+1 < track.zones.Length ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("new", "Insert new zone after", track.zones.Length >= MAX_ZONES_PER_TRACK ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("", "", ITEMDRAW_SPACER);
	menu.AddItem("drop", "Drop this zone");
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int HandleEditZoneMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	} else if (action == MenuAction_Cancel) {
		if (param2 == MenuCancel_ExitBack) {
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
			ShowPickZoneMenu(param1);
		} else {
			//menu went away by exit, disconnect, was interruped by something else, ...
			clientEditorState[param1] = EDIT_NONE;
			clientTrackEditIndex[param1] = INVALID_TRACK;
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
		}
	} else if (action == MenuAction_Select) {
		Track track;
		track.FetchSelf(clientTrackEditIndex[param1]);
		//we don't need to push because we're only editing values behind a handle
		char info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		ZoneData zone;
		if (StrEqual(info, "mins") || StrEqual(info, "maxs")) {
			bool high = (info[1]=='a');
			track.zones.GetArray(clientZoneEditIndex[param1], zone);
			//calc new bound
			float pos[3],off[3];
			Entity_GetAbsOrigin(param1, pos);
			if (high) {
				Entity_GetMaxSize(param1, off);
				AddVectors(pos,off,zone.maxs);
			} else {
				Entity_GetMinSize(param1, off);
				AddVectors(pos,off,zone.mins);
			}
			//sort min/max
			for (int i=0;i<3;i+=1) {
				if (zone.mins[i] > zone.maxs[i]) {
					float swap = zone.mins[i];
					zone.mins[i] = zone.maxs[i];
					zone.maxs[i] = swap;
				}
			}
			track.zones.SetArray(clientZoneEditIndex[param1], zone);
			//re-open menu
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "next")) {
			if (clientZoneEditIndex[param1] + 1 < track.zones.Length)
				clientZoneEditIndex[param1] += 1;
			else
				PrintToChat(param1, "[QT] Cannot skip after last zone");
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "prev")) {
			if (clientZoneEditIndex[param1] > 0)
				clientZoneEditIndex[param1] -= 1;
			else
				PrintToChat(param1, "[QT] Cannot skip before first zone");
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "new")) {
			if (track.zones.Length < MAX_ZONES_PER_TRACK) {
				zone.track = clientTrackEditIndex[param1];
				int index = (clientZoneEditIndex[param1] + 1); //insert after
				if (index < track.zones.Length) {
					track.zones.ShiftUp(index);
					track.zones.SetArray(index, zone);
					clientZoneEditIndex[param1] = index;
				} else {
					clientZoneEditIndex[param1] = track.zones.PushArray(zone);
				}
			} else {
				PrintToChat(param1, "[QT] Could not create zone, limit reached");
			}
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "drop")) {
			track.zones.Erase(clientZoneEditIndex[param1]);
			int remain = track.zones.Length;
			//if no zones remain, drop one menu level
			if (!remain) {
				clientZoneEditIndex[param1] = ZONE_EDITNONE;
				ShowPickZoneMenu(param1);
				return 0;
			}
			//if tail was poped reduce edit index
			if (clientZoneEditIndex[param1] >= remain) {
				clientZoneEditIndex[param1] = remain-1;
			}
			//edit remaining / next zone
			ShowEditZoneMenu(param1);
		}
	}
	return 0;
}

void ShowPickZoneMenu(int client) {
	if (clientEditorState[client] != EDIT_ZONE) {
		PrintToChat(client, "[QT] You are not editing any zone at the moment");
		return;
	}
	if (clientZoneEditIndex[client] != ZONE_EDITNONE) {
		ShowEditZoneMenu(client);
		return;
	}
	Menu menu = CreateMenu(HandlePickZoneMenu);
	Track track;
	track.FetchSelf(clientTrackEditIndex[client]);
	if (track.zones.Length > 0)
		menu.SetTitle("Editing Track\n %s\nUse say_team to pick a zone (1..%i)", track.name, track.zones.Length);
	else
		menu.SetTitle("Editing Track\n %s\nThis track is currently empty", track.name);
	
	menu.AddItem("first", "Go to first", (track.zones.Length == 0) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("last", "Go to last", (track.zones.Length == 0) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("insert", "Insert new first", (track.zones.Length >= MAX_ZONES_PER_TRACK) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	menu.AddItem("append", "Append new last", (track.zones.Length >= MAX_ZONES_PER_TRACK) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
	if (track.zones.Length >= MAX_ZONES_PER_TRACK) {
		menu.AddItem("", "Zone limit reached", ITEMDRAW_DISABLED);
	}
	
	menu.ExitBackButton = true;
	menu.Display(client, 15);
}

public int HandlePickZoneMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	} else if (action == MenuAction_Cancel) {
		if (param2 == MenuCancel_ExitBack) {
			clientEditorState[param1] = EDIT_TRACK;
			ShowEditTrackMenu(param1);
		} else if (param2 != MenuCancel_Interrupted || clientEditorState[param1] != EDIT_ZONE || clientZoneEditIndex[param1] == ZONE_EDITNONE) {
			//menu went away by exit, disconnect, ... OR was interruped by something other than the zone edit menu on a known zone index
			clientEditorState[param1] = EDIT_NONE;
			clientTrackEditIndex[param1] = INVALID_TRACK;
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
		}
	} else if (action == MenuAction_Select) {
		Track track;
		track.FetchSelf(clientTrackEditIndex[param1]);
		//we don't need to push because we're only editing values behind a handle
		char info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		ZoneData zone;
		zone.track = clientTrackEditIndex[param1];
		if (track.zones.Length >= MAX_ZONES_PER_TRACK) {
			PrintToChat(param1, "[QT] Could not create zone, limit reached");
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
			ShowPickZoneMenu(param1);
		} else if (StrEqual(info, "first")) {
			//open menu on zone 0
			clientZoneEditIndex[param1] = 0;
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "last")) {
			//open menu on last zone
			clientZoneEditIndex[param1] = track.zones.Length-1;
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "insert")) {
			//insert zone at front
			if (track.zones.Length) {
				track.zones.ShiftUp(0);
				track.zones.SetArray(0,zone);
			} else {
				track.zones.PushArray(zone);
			}
			clientZoneEditIndex[param1] = 0;
			//open menu
			ShowEditZoneMenu(param1);
		} else if (StrEqual(info, "append")) {
			//insert zone at end
			int tail = track.zones.PushArray(zone);
			clientZoneEditIndex[param1] = tail;
			//open menu
			ShowEditZoneMenu(param1);
		}
	}
	return 0;
}

void ShowEditLapsMenu(int client) {
	if (clientEditorState[client] != EDIT_TRACKSUB) {
		PrintToChat(client, "[QT] You are not editing any track at the moment");
		return;
	}
	Menu menu = CreateMenu(HandleEditLapsMenu);
	Track track;
	track.FetchSelf(clientTrackEditIndex[client]);
	menu.SetTitle("Editing Track\n %s\n %i Lap(s)", track.name, track.laps);
	menu.AddItem("0", "Linear");
	menu.AddItem("1", "1 Lap");
	menu.AddItem("2", "2 Laps");
	menu.AddItem("3", "3 Laps");
	menu.AddItem("4", "4 Laps");
	menu.AddItem("5", "5 Laps");
	menu.AddItem("6", "6 Laps");
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int HandleEditLapsMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	} else if (action == MenuAction_Cancel) {
		if (param2 == MenuCancel_ExitBack) {
			clientEditorState[param1] = EDIT_TRACK;
			ShowEditTrackMenu(param1);
		} else {
			//menu went away by exit, disconnect, was interruped by something else, ...
			clientEditorState[param1] = EDIT_NONE;
			clientTrackEditIndex[param1] = INVALID_TRACK;
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
		}
	} else if (action == MenuAction_Select) {
		Track track;
		track.FetchSelf(clientTrackEditIndex[param1]);
		//we don't need to push because we're only editing values behind a handle
		char info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		
		int laps = StringToInt(info);
		track.laps = laps;
		track.PushSelf(clientTrackEditIndex[param1]);
		
		ShowEditLapsMenu(param1);
	}
	return 0;
}

void ShowEditRulesMenu(int client, int firstItem=0) {
	if (clientEditorState[client] != EDIT_TRACKSUB) {
		PrintToChat(client, "[QT] You are not editing any track at the moment");
		return;
	}
	
	Menu menu = CreateMenu(HandleEditRulesMenu);
	Track track;
	char buffer[32];
	track.FetchSelf(clientTrackEditIndex[client]);
	
	menu.SetTitle("Editing Track\n %s\n Set Rules", track.name);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(0) ? 'X' : ' ', gMenuClassNames[0]);
	menu.AddItem("0", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(1) ? 'X' : ' ', gMenuClassNames[1]);
	menu.AddItem("1", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(2) ? 'X' : ' ', gMenuClassNames[2]);
	menu.AddItem("2", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(3) ? 'X' : ' ', gMenuClassNames[3]);
	menu.AddItem("3", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(4) ? 'X' : ' ', gMenuClassNames[4]);
	menu.AddItem("4", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(5) ? 'X' : ' ', gMenuClassNames[5]);
	menu.AddItem("5", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(6) ? 'X' : ' ', gMenuClassNames[6]);
	menu.AddItem("6", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(7) ? 'X' : ' ', gMenuClassNames[7]);
	menu.AddItem("7", buffer);
	Format(buffer, sizeof(buffer), "[%c] %s", track.rules & RULE_CLASS(8) ? 'X' : ' ', gMenuClassNames[8]);
	menu.AddItem("8", buffer);
	Format(buffer, sizeof(buffer), "[%c] No Demo Charging", track.rules & RULE_NOCHARGE ? 'X' : ' ');
	menu.AddItem("9", buffer);
	Format(buffer, sizeof(buffer), "[%c] Only Taunts", track.rules & RULE_TAUNTONLY ? 'X' : ' ');
	menu.AddItem("10", buffer);
	Format(buffer, sizeof(buffer), "[%c] Only Vehicle Taunts", track.rules & RULE_VEHICLEONLY ? 'X' : ' ');
	menu.AddItem("11", buffer);
	Format(buffer, sizeof(buffer), "[%c] Dont Jump", track.rules & RULE_DONTJUMP ? 'X' : ' ');
	menu.AddItem("12", buffer);
	Format(buffer, sizeof(buffer), "[%c] Dont Land after Airborn", track.rules & RULE_DONTLAND ? 'X' : ' ');
	menu.AddItem("13", buffer);
	
	menu.ExitBackButton = true;
	menu.DisplayAt(client, firstItem, MENU_TIME_FOREVER);
}

public int HandleEditRulesMenu(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_End) {
		delete menu;
	} else if (action == MenuAction_Cancel) {
		if (param2 == MenuCancel_ExitBack) {
			clientEditorState[param1] = EDIT_TRACK;
			ShowEditTrackMenu(param1);
		} else {
			//menu went away by exit, disconnect, was interruped by something else, ...
			clientEditorState[param1] = EDIT_NONE;
			clientTrackEditIndex[param1] = INVALID_TRACK;
			clientZoneEditIndex[param1] = ZONE_EDITNONE;
		}
	} else if (action == MenuAction_Select) {
		Track track;
		track.FetchSelf(clientTrackEditIndex[param1]);
		//we don't need to push because we're only editing values behind a handle
		char info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		
		int ruleFlag = 1<<StringToInt(info);
		track.rules ^= ruleFlag;
		track.PushSelf(clientTrackEditIndex[param1]);
		
		ShowEditRulesMenu(param1, (param2/7)*7);
	}
	return 0;
}

int g_colStart[4] = { 0,255,0,255 };
int g_colEnd[4] = { 255,0,0,255 };
int g_colWhite[4] = { 255,255,255,255 };
int g_colActive[4] = { 255,200,0,255 };
public Action Timer_DrawZones(Handle timer) {
	//to not overwhelm the te system, the draws are split up using a timer
	
	static int client = 1;
	int start = client;
	for (int i; i<TIMER_PLAYERS_PER_TICK; i++) {
		if (++client > SPLIT_TIMER_FOR_PLAYERS) client = 1;
		if (start == client) break; //we are repeating
		DrawZonesFor(client);
	}
	
	return Plugin_Continue;
}
void DrawZonesFor(int client) {
	if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client)<2) {
		return;
	}
	
	Track track;
	ZoneData zone;
	
	if (clientEditorState[client] != EDIT_NONE) {
		track.FetchSelf(clientTrackEditIndex[client]);
		int lastZone = track.zones.Length-1;
		float tppp[3], tppt[3]; // tele-port point prev/this
		for (int i=0;i<=lastZone;i++) {
			track.zones.GetArray(i,zone);
			tppp = tppt; //track line prev to this
			zone.GetTelepoint(tppt);
			if (GetClientPointDistance(client, tppt, true) < 9000000.0) {
				//keep a render dinstace, so draw calls don't fill up as easily
				if (i==0)
					DrawBeamBox(client, zone.mins, zone.maxs, 2.0, g_colStart, i==clientZoneEditIndex[client]);
				else if (i==lastZone && !track.laps)
					DrawBeamBox(client, zone.mins, zone.maxs, 2.0, g_colEnd, i==clientZoneEditIndex[client]);
				else if (i==clientZoneEditIndex[client]) 
					DrawBeamBox(client, zone.mins, zone.maxs, 2.0, g_colActive, i==clientZoneEditIndex[client]);
			}
			//track line
			if (i!=0 && (i==clientZoneEditIndex[client] || (i-1)==clientZoneEditIndex[client]))
				DrawBeamSimple(client, tppp, tppt, 1.0, g_colWhite);
		}
		
	} else if (clientAttempts[client].track == INVALID_TRACK) {
		//no active tracks, draw all starts
		for (int t=0; t<g_Tracks.Length; t+=1) {
			if (Track_IsInEditor(t)) continue;
			track.FetchSelf(t);
			if (!track.open || track.zones.Length<=1) continue;
			track.zones.GetArray(0, zone);
			DrawBeamBox(client, zone.mins, zone.maxs, 3.0, g_colStart);
		}
	} else {
		track.FetchSelf(clientAttempts[client].track);
		int lastZone = track.zones.Length-1;
		int nextZone = clientAttempts[client].zone == ZONE_INSTART ? 1 : clientAttempts[client].zone + 1;
		if (nextZone > lastZone) nextZone = 0;
		
		float vec[3];
		track.zones.GetArray(0,zone);
		zone.GetTelepoint(vec);
		if (GetClientPointDistance(client, vec, true) < 9000000.0) {
			//keep a render dinstace, so draw calls don't fill up as easily
			bool lastLap = track.laps && clientAttempts[client].lap == track.laps;
			DrawBeamBox(client, zone.mins, zone.maxs, 3.0, lastLap ? g_colEnd : g_colStart);
		}
		if (nextZone != 0 && (nextZone != lastZone || track.laps)) {
			track.zones.GetArray(nextZone,zone);
			zone.GetTelepoint(vec);
			if (GetClientPointDistance(client, vec, true) < 9000000.0)
				DrawBeamBox(client, zone.mins, zone.maxs, 2.0, g_colActive);
		}
		if (!track.laps) {
			track.zones.GetArray(lastZone,zone);
			zone.GetTelepoint(vec);
			if (GetClientPointDistance(client, vec, true) < 9000000.0)
				DrawBeamBox(client, zone.mins, zone.maxs, 3.0, g_colEnd);
		}
	}
}

float GetClientPointDistance(int client, const float vec[3], bool squared=false) {
	float pos[3];
	Entity_GetAbsOrigin(client,pos);
	return GetVectorDistance(pos,vec,squared);
}

void SaveTracks() {
	char mapname[72];
	char buffer[128];
	GetCurrentMap(mapname,sizeof(mapname));
	KeyValues kv = CreateKeyValues("Tracks");
	if (!DirExists("cfg/tracks") && !CreateDirectory("cfg/tracks", FPERM_O_READ|FPERM_O_EXEC|FPERM_G_READ|FPERM_G_EXEC|FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC)) {
		PrintToServer("Could not create tracks directory, saving failed!");
		return;
	}
	
	Track track; int count;
	ZoneData zone;
	for (int i=0;i<g_Tracks.Length;i++) {
		g_Tracks.GetArray(i,track);
		if (!track.open || track.zones.Length == 0) continue;
		count++;
		
		kv.JumpToKey(track.name, true); {
			kv.SetNum("laps", track.laps);
			kv.JumpToKey("rules", true); {
				buffer[0]=0;
				for (int c=0;c<9;c++) {
					if ((track.rules & RULE_CLASS(c))) {
						StrCat(buffer, sizeof(buffer), " ");
						StrCat(buffer, sizeof(buffer), gMenuClassNames[c]);
						TrimString(buffer);
					}
				}
				kv.SetString("classes", buffer);
				kv.SetNum("no_demo_charge", (track.rules & RULE_NOCHARGE)!=0);
				kv.SetNum("taunts_only", (track.rules & RULE_TAUNTONLY)!=0);
				kv.SetNum("vehicle_only", (track.rules & RULE_VEHICLEONLY)!=0);
				kv.SetNum("dont_jump", (track.rules & RULE_DONTJUMP)!=0);
				kv.SetNum("dont_land", (track.rules & RULE_DONTLAND)!=0);
			} kv.GoBack();
			kv.JumpToKey("zones", true); {
				for (int z=0;z<track.zones.Length;z++) {
					track.zones.GetArray(z,zone);
					
					Format(buffer,sizeof(buffer),"%d",(z+1));
					kv.JumpToKey(buffer, true); {
						kv.SetVector("low", zone.mins);
						kv.SetVector("high", zone.maxs);
					} kv.GoBack();
				}
			} kv.GoBack();
		} kv.GoBack();
	}
	
	Format(buffer, sizeof(buffer), "cfg/tracks/%s.cfg", mapname);
	if (count) {
		kv.Rewind();
		kv.ExportToFile(buffer);
	} else if (kv.ImportFromFile(buffer)) {
		//we had a file, but zones were all deleted
		DeleteFile(buffer);
	}
	delete kv;
}
void LoadTracks() {
	char mapname[72];
	char buffer[128];
	GetCurrentMap(mapname,sizeof(mapname));
	KeyValues kv = CreateKeyValues("Tracks");
	
	Track track;
	ZoneData zone;
	
	Format(buffer, sizeof(buffer), "cfg/tracks/%s.cfg", mapname);
	kv.ImportFromFile(buffer);
	if (kv.GotoFirstSubKey()) do {
		track.Reinit(-1);
		kv.GetSectionName(track.name, sizeof(Track::name));
		track.open = true;
		track.laps = kv.GetNum("laps");
		if (kv.JumpToKey("rules")) {
			kv.GetString("classes", buffer, sizeof(buffer));
			track.rules = 0;
			for (int z=0;z<9;z++) {
				if (StrContains(buffer, gMenuClassNames[z], false)>=0)
					track.rules |= RULE_CLASS(z);
			}
			if (kv.GetNum("no_demo_charge"))
				track.rules |= RULE_NOCHARGE;
			if (kv.GetNum("taunts_only"))
				track.rules |= RULE_TAUNTONLY;
			if (kv.GetNum("vehicle_only"))
				track.rules |= RULE_VEHICLEONLY;
			if (kv.GetNum("dont_jump"))
				track.rules |= RULE_DONTJUMP;
			if (kv.GetNum("dont_land"))
				track.rules |= RULE_DONTLAND;
			kv.GoBack();
		} else {
			PrintToServer("Could not load rules for track %s", track.name);
		}
		if (kv.JumpToKey("zones")) {
			for (int z=1;;z++) {
				Format(buffer,sizeof(buffer),"%d",z);
				if (!kv.JumpToKey(buffer)) break; //all zones get
				kv.GetVector("low", zone.mins);
				kv.GetVector("high", zone.maxs);
				track.zones.PushArray(zone);
				kv.GoBack();
			}
			kv.GoBack();
		} else {
			PrintToServer("Track %s could not be loaded, no zones found", track.name);
			continue; //don't load this track
		}
		track.PushSelf();
	} while (kv.GotoNextKey());
	
	delete kv;
}

#define BEAM(%1,%2) TE_SetupBeamPoints(%1, %2, g_iLaserBeam, 0, 0, 1, 1.0, width, width, 0, 0.0, color, 0);TE_SendToClient(client)
void DrawBeamBox(int client, const float mins[3], const float maxs[3], float width, const int color[4], bool diag=false) {
	float vecl[4][3], vech[4][3];
	//vecl for the lower 4 corners, vech for the upper 4 corners
	//idx 0 is at lows, idx 2 at highs, 1 at x-max, 3 at y-max
	vecl[0] = mins;
	vech[0] = mins;
	vech[0][2] = maxs[2];
	vecl[2] = maxs;
	vech[2] = maxs;
	vecl[2][2] = mins[2];
	vecl[1] = vecl[0];
	vecl[3] = vecl[0];
	vech[1] = vech[0];
	vech[3] = vech[0];
	vecl[1][0] = vech[1][0] = maxs[0];
	vecl[3][1] = vech[3][1] = maxs[1];
	//draw lower ring
	BEAM(vecl[0], vecl[1]);
	BEAM(vecl[1], vecl[2]);
	BEAM(vecl[2], vecl[3]);
	BEAM(vecl[3], vecl[0]);
	//draw upper ring
	BEAM(vech[0], vech[1]);
	BEAM(vech[1], vech[2]);
	BEAM(vech[2], vech[3]);
	BEAM(vech[3], vech[0]);
	//draw remaining 4 standing edges
	BEAM(vecl[0], vech[0]);
	BEAM(vecl[1], vech[1]);
	BEAM(vecl[2], vech[2]);
	BEAM(vecl[3], vech[3]);
	if (diag) {
		BEAM(mins,maxs);
	}
}
void DrawBeamSimple(int client, const float start[3], const float end[3], float width, const int color[4]) {
	BEAM(start,end);
}
//void DrawTrackBeam(int client, int track, float width, const int color[4]) {
//	Track track;
//	track.FetchSelf(track);
//	ZoneData zone;
//	float veca[3], vecb[3];
//	bool draw;
//	for (int i=track.zones.Length-1; i>=0; i-=1) {
//		vecb = veca;
//		track.zones.GetArray(i);
//		zone.GetTelepoint(veca);
//		if (draw) {
//			BEAM(veca,vecb);
//		} else draw = true;
//	}
//}
#undef BEAM