#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#include <smlib>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "23w01a"

public Plugin myinfo = {
	name = "MapProps",
	author = "reBane",
	description = "Prop handling for admins",
	version = PLUGIN_VERSION,
	url = "N/A"
};

#define PERM_MOD ADMFLAG_GENERIC

char g_clientSteamId[MAXPLAYERS+1][64];
char g_currentMapName[128];
ArrayList g_mapProps;
Database g_db = null;
bool g_dbConnected;
int g_iEdictBuffer;

enum struct LocalPropData {
	char model[PLATFORM_MAX_PATH];
	char owner[64]; //steamid
	float origin[3];
	float rotation[3];
	int color[4];
	bool physics;
	bool saved;
	int entref;

	void SaveAsync() {
		if (this.saved) return; //already saved
		//re-read position in case of things like physgun
		int entity=EntRefToEntIndex(this.entref);
		if (entity != INVALID_ENT_REFERENCE) {
			Entity_GetAbsOrigin(entity, this.origin);
			Entity_GetAbsAngles(entity, this.rotation);
			Entity_GetRenderColor(entity, this.color);
		}
		//push to database
		char buffer[1024];
		g_db.Format(buffer, sizeof(buffer), "INSERT INTO mapprops (map, model, owner, posx, posy, posz, pitch, yaw, roll, color) VALUES ('%s', '%s', '%s', %f, %f, %f, %f, %f, %f, %i)",
			g_currentMapName, this.model, this.owner, this.origin[0], this.origin[1], this.origin[2], this.rotation[0], this.rotation[1], this.rotation[2], ColorToInt(this.color));
		SQL_FastAsync(buffer);
		this.saved = true;
	}
	void Restore(int useIndex) {
		if (EntRefToEntIndex(this.entref) == INVALID_ENT_REFERENCE) {
			//try to get the prop back from world (maybe the plugin reloaded?)
			int entity;
			for (int search=MaxClients+1; search < 2048; search+=1) { //2048 == edict limit
				char buffer[PLATFORM_MAX_PATH];
				float origin[3], angles[3];
				int color[4];
				if (!IsValidEdict(search) || !GetEntityClassname(search,buffer,sizeof(buffer)) || StrContains(buffer,this.physics?"prop_physics":"prop_dynamic")!=0) continue;
				//we have some prop, is it at the correct position?
				Entity_GetAbsOrigin(search, origin);
				Entity_GetAbsAngles(search, angles);
				Entity_GetRenderColor(search, color);
				bool different;
				for (int i=0;i<3;i++) {
					float d;
					if ((d = this.origin[i]-origin[i])<0) d=-d;
					if (d>0.5) {different=true;break;}
					if ((d = this.rotation[i]-angles[i])<0) d=-d;
					if (d>0.5) {different=true;break;}
					if (this.color[i]!=color[i]) {different=true;break;}
				}
				if (different || this.color[3]!=color[3]) { //alpha channel is not checked in loop
					continue; //not the prop we're looking for
				}
				//does it have the same model
				Entity_GetModel(search, buffer, sizeof(buffer));
				if (StrEqual(this.model, buffer)) {
					entity = search;
					break;
				}
			}
			if (!entity) {
				entity = SpawnOwnedPropAt(this.model, this.owner, this.origin, this.rotation, this.physics, useIndex);
				if (entity != INVALID_ENT_REFERENCE) {
					SetEntityRenderMode(entity, this.color[3]==255?RENDER_NORMAL:RENDER_TRANSCOLOR);
					Entity_SetRenderColor(entity, this.color[0], this.color[1], this.color[2], this.color[3]);
					this.entref = EntIndexToEntRef(entity);
				} else
					PrintToServer("[MapProps] - WARNING: failed to restore prop");
			}
		}
	}
	void DropAsync() {
		if (!this.saved) return; //not saved
		char buffer[1024];
		g_db.Format(buffer, sizeof(buffer), "DELETE FROM mapprops WHERE map='%s' AND model='%s' AND owner='%s' AND ABS(posx - %f)<1.0 AND ABS(posy - %f)<1.0 AND ABS(posz - %f)<1.0 AND ABS(pitch - %f)<1.0 AND ABS(yaw - %f)<1.0 AND ABS(roll - %f)<1.0",
			g_currentMapName, this.model, this.owner, this.origin[0], this.origin[1], this.origin[2], this.rotation[0], this.rotation[1], this.rotation[2]);
		SQL_FastAsync(buffer);
		this.saved = false;
	}
	bool Update(int selfIndex=-1) {
		float origin[3], angles[3];
		int color[4];
		int entity = EntRefToEntIndex(this.entref);
		if (entity == INVALID_ENT_REFERENCE) {
			if (this.saved) this.DropAsync();
			return false;
		}
		Entity_GetAbsOrigin(entity, origin);
		Entity_GetAbsAngles(entity, angles);
		Entity_GetRenderColor(entity, color);
		if (this.saved) {
			//only update database if moved. reduces db stress
			bool doupdate;
			for (int i=0;i<3;i++) {
				float d;
				if ((d = this.origin[i]-origin[i])<0) d=-d;
				if (d>0.5) {doupdate=true;break;}
				if ((d = this.rotation[i]-angles[i])<0) d=-d;
				if (d>0.5) {doupdate=true;break;}
				if (this.color[i]!=color[i]) {doupdate=true;break;}
			}
			if (doupdate || this.color[3]!=color[3]) { //alpha channel is not checked in loop
				this.DropAsync();
				this.SaveAsync();
				if (selfIndex>=0) g_mapProps.SetArray(selfIndex, this);
			}
		} else {
			this.origin = origin;
			this.rotation = angles;
			this.color = color;
			if (selfIndex>=0) g_mapProps.SetArray(selfIndex, this);
		}
		return true;
	}
	bool ImportFrom(int entity, int owner) {
		if (!IsValidEntity(entity)) return false;
		char classname[64];
		if (!GetEntityClassname(entity, classname, sizeof(classname))) return false;
		if (StrContains(classname, "prop_physics")==0) this.physics = true;
		else if (StrContains(classname, "prop_dynamic")==0) this.physics = false;
		else return false;
		Entity_GetModel(entity, this.model, sizeof(LocalPropData::model));
		strcopy(this.owner, sizeof(LocalPropData::owner), g_clientSteamId[owner]);
		Entity_GetAbsOrigin(entity, this.origin);
		Entity_GetAbsAngles(entity, this.rotation);
		Entity_GetRenderColor(entity, this.color);
		this.saved = false;
		this.entref = EntIndexToEntRef(entity);
		return true;
	}
}

public void OnPluginStart() {
	LoadTranslations("common.phrases");
	
	RegAdminCmd("sm_spawnprop", Command_SpawnProp, PERM_MOD, "<modelpath> - Spawns a prop with the given model in front of you");
	RegAdminCmd("sm_spawnphys", Command_SpawnProp, PERM_MOD, "<modelpath> - Spawns a prop with the given model in front of you");
	RegAdminCmd("sm_deleteprop", Command_DeleteProp, PERM_MOD, "[entRef] - Deletes the prop looking at");
	RegAdminCmd("sm_deletepropsby", Command_DeleteProp2, PERM_MOD, "<SteamID2|UserID|Target> - Deletes all props by the specified owner");
	RegAdminCmd("sm_freezeprop", Command_FreezeProp, PERM_MOD, "Freezes the prop looking at");
	RegAdminCmd("sm_unfreezeprop", Command_UnfreezeProp, PERM_MOD, "Unfreezes the prop looking at");
	if (SQL_CheckConfig("MapProps")) {
		RegAdminCmd("sm_saveprop", Command_SaveProp, PERM_MOD, "Saves the prop looking at in database");
		RegAdminCmd("sm_removeprop", Command_RemoveProp, PERM_MOD, "Removes the prop looking at from database");
	}
	RegAdminCmd("sm_propowner", Command_PropInfo, PERM_MOD, "Gets who spawned prop looking at in case of furniture");
	RegAdminCmd("sm_propmodel", Command_PropModel, PERM_MOD, "Gets model path of prop looking at");
	RegAdminCmd("sm_colorprop", Command_ColorProp, PERM_MOD, "<r=0..255> <g=0..255> <b=0..255> [a=50..255] - Change prop color");

	ConVar convar = FindConVar("sv_lowedict_threshold");
	if (convar != null) {
		g_iEdictBuffer = convar.IntValue;
		convar.AddChangeHook(OnLowedictThresholdChanged);
	}

	//hook this event as this nukes props
	HookEvent("teamplay_round_start", OnRoundStart);

	//late load handling
	g_clientSteamId[0] = "SERVER";
	for (int client=1;client<=MaxClients;client++) {
		if (IsClientAuthorized(client)) {
			OnClientAuthorized(client, "");
		}
	}
}

public void OnMapStart() {
	if (!(g_dbConnected = (g_db!=null))) {
		Database.Connect(SQL_OnConnected, "MapProps");
	}
	if (g_mapProps==null) g_mapProps = new ArrayList(sizeof(LocalPropData));
	else g_mapProps.Clear();
	
	GetCurrentMap(g_currentMapName, sizeof(g_currentMapName));
	LoadProps(false);
}

public void OnPluginEnd() {
	for (int i=g_mapProps.Length-1; i>=0; i--) {
		int entity = EntRefToEntIndex(g_mapProps.Get(i,LocalPropData::entref));
		if (entity != INVALID_ENT_REFERENCE) {
			AcceptEntityInput(entity, "Kill");
		}
	}
	g_mapProps.Clear();
	delete g_db;
}

Action OnRoundStart(Event event, const char[] name, bool dontBroadcast) {
	if (event.GetBool("full_reset"))
		LoadProps();
	return Plugin_Continue;
}

public void OnClientAuthorized(int client, const char[] auth) {
	GetClientAuthId(client, AuthId_Steam2, g_clientSteamId[client], sizeof(g_clientSteamId[]));
}
public void OnClientDisconnect(int client) {
	g_clientSteamId[client][0]=0;
}

//#region ConVars
public void OnLowedictThresholdChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_iEdictBuffer = convar.IntValue;
}

//#endregion

//#region Commands

Action Command_SpawnProp(int client, int args) {
	char buff[128];
	GetCmdArg(0, buff, sizeof(buff));
	bool physics = StrContains(buff, "phys")>0;
	GetCmdArgString(buff, sizeof(buff));
	int ent = SpawnPropAtClient(client, buff, physics);
	if (ent == INVALID_ENT_REFERENCE)
		ReplyToCommand(client, "[SM] Could not spawn prop");
	else 
		ReplyToCommand(client, "[SM] Spawned prop_%s with ref %08X", physics?"physics":"dynamic", EntIndexToEntRef(ent));
	return Plugin_Handled;
}

Action Command_DeleteProp(int client, int args) {
	int entity = FindCommandTargetEntity(client);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	LocalPropData local;
	int index;
	if (GetMapPropByRef(entity, local, index)) {
		local.DropAsync();
		g_mapProps.Erase(index);
	}
	int ref = EntIndexToEntRef(entity);// for printing
	AcceptEntityInput(entity, "Kill");
	ReplyToCommand(client, "[SM] Deleted prop ref %08X", ref);
	return Plugin_Handled;
}

Action Command_DeleteProp2(int client, int args) {
	if (args == 0) {
		ReplyToCommand(client, "[SM] Usage: /deletepropby <SteamID2|UserID|Target>");
		return Plugin_Handled;
	}
	int deleted;
	char buffer[128];
	GetCmdArgString(buffer, sizeof(buffer));
	if (StrContains(buffer, "steam_", false)==0) {
		//this loop is an ascii StrToUpper, because steam2 ids should be caps prefixed (STEAM_)
		for (int i=strlen(buffer)-1; i>=0; i-=1) {
			if ('a'<=buffer[i]<='z') buffer[i] &=~ ' ';
		}
		deleted = DeleteAllPropsBySteamId(buffer);
		int target = GetClientBySteamId(buffer);
		if (target)
			ReplyToCommand(client, "[SM] Deleted %i props (cache+map) for %N (%s)...", deleted, target, buffer);
		else
			ReplyToCommand(client, "[SM] Deleted %i props (cache+map) for SteamID '%s'...", deleted, buffer);
	} else {
		int targets[MAXPLAYERS];
		bool tn_is_ml;
		char tname[64];
		int result = ProcessTargetString(buffer, client, targets, MAXPLAYERS, COMMAND_FILTER_NO_IMMUNITY|COMMAND_FILTER_NO_BOTS, tname, sizeof(tname), tn_is_ml);
		if (result <= 0) {
			ReplyToTargetError(client, result);
			return Plugin_Handled;
		}
		for (int i=0; i<result; i+=1) {
			if (!GetClientAuthId(targets[i], AuthId_Steam2, buffer, sizeof(buffer)))
				continue;
			deleted += DeleteAllPropsBySteamId(buffer);
		}
		if (tn_is_ml) {
			ReplyToCommand(client, "[SM] Deleted %i props (cache+map) for %t", deleted, tname);
		} else {
			ReplyToCommand(client, "[SM] Deleted %i props (cache+map) for %s", deleted, tname);
		}
	}
	return Plugin_Handled;
}

Action Command_FreezeProp(int client, int args) {
	int entity = FindCommandTargetEntity(client, .onlyPhysics=true);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	Entity_SetTakeDamage(entity, DAMAGE_NO);
	Entity_DisableMotion(entity);
	ReplyToCommand(client, "[SM] Froze prop ref %08X", EntIndexToEntRef(entity));
	return Plugin_Handled;
}
Action Command_UnfreezeProp(int client, int args) {
	int entity = FindCommandTargetEntity(client, .onlyPhysics=true);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	Entity_SetTakeDamage(entity, DAMAGE_EVENTS_ONLY);
	Entity_EnableMotion(entity);

	LocalPropData local;
	int index;
	if (GetMapPropByRef(entity, local, index) && local.saved) {
		local.DropAsync();
		ReplyToCommand(client, "[SM] Removed prop ref %08X from database and unfroze", EntIndexToEntRef(entity));
	} else {
		ReplyToCommand(client, "[SM] Unfroze entity ref %08X", EntIndexToEntRef(entity));
	}
	return Plugin_Handled;
}
Action Command_SaveProp(int client, int args) {
	int entity = FindCommandTargetEntity(client);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	LocalPropData local;
	int index;
	if (GetMapPropByRef(entity, local, index, client)) {
		if (local.physics) {
			Entity_SetTakeDamage(entity, DAMAGE_NO);
			Entity_DisableMotion(entity);
		}
		if (local.saved) local.Update(index); else local.SaveAsync();
		ReplyToCommand(client, "[SM] Saved prop ref %08X to database", EntIndexToEntRef(entity));
	} else {
		ReplyToCommand(client, "[SM] This prop is invalid");
	}
	return Plugin_Handled;
}
Action Command_RemoveProp(int client, int args) {
	int entity = FindCommandTargetEntity(client);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	LocalPropData local;
	int index;
	if (GetMapPropByRef(entity, local, index)) {
		local.DropAsync();
		ReplyToCommand(client, "[SM] Removed prop ref %08X from database", EntIndexToEntRef(entity));
	} else {
		ReplyToCommand(client, "[SM] This prop is invalid");
	}
	return Plugin_Handled;
}
Action Command_PropInfo(int client, int args) {
	int entity = FindCommandTargetEntity(client);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	LocalPropData local;
	int index;
	if (GetMapPropByRef(entity, local, index)) {
		int owner = GetClientBySteamId(local.owner);
		char buffer[1024];
		if (owner) Format(buffer, sizeof(buffer), "[SM] Prop ref %08X was spawned by %N (%s #%i)", EntIndexToEntRef(entity), owner, local.owner, GetClientUserId(owner));
		else Format(buffer, sizeof(buffer), "[SM] Prop ref %08X was spawned by %s (offline)", EntIndexToEntRef(entity), local.owner);
		if (local.saved) StrCat(buffer, sizeof(buffer), " and saved");
		ReplyToCommand(client, "%s", buffer);
	} else {
		ReplyToCommand(client, "[SM] This prop is not owned");
	}
	return Plugin_Handled;
}
Action Command_PropModel(int client, int args) {
	int entity = FindCommandTargetEntity(client);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;

	char model[PLATFORM_MAX_PATH];
	Entity_GetModel(entity, model, sizeof(model));
	ReplyToCommand(client, "[SM] Prop ref %08X uses model %s", EntIndexToEntRef(entity), model);
	return Plugin_Handled;
}

Action Command_ColorProp(int client, int args) {
	int entity = FindCommandTargetEntity(client, .cursorOnly=true);
	if (entity == INVALID_ENT_REFERENCE) return Plugin_Handled;
	if (args < 3 || args > 4) {
		ReplyToCommand(client, "[SM] Usage: sm_colorprop <r> <g> <b> [a]");
		return Plugin_Handled;
	}
	int color[4];
	char buffer[12];
	for (int i=0;i<3;i++) {
		GetCmdArg(i+1,buffer,sizeof(buffer));
		color[i] = StringToInt(buffer);
	}
	if (args == 4) {
		GetCmdArg(4,buffer,sizeof(buffer));
		color[3] = StringToInt(buffer);
	} else {
		color[3] = 255;
	}
	for (int i=0;i<4;i++) {
		if (color[i] < 0) color[i]=0;
		if (color[i] > 255) color[i]=255;
	}
	if (color[3]<50) color[3]=50; //min alpha

	SetEntityRenderMode(entity, color[3]==255?RENDER_NORMAL:RENDER_TRANSCOLOR);
	Entity_SetRenderColor(entity, color[0], color[1], color[2], color[3]);

	LocalPropData local;
	int index;
	if (GetMapPropByRef(entity, local, index)) {
		local.Update(index);
	}
	ReplyToCommand(client, "[SM] Prop ref %08X was colored", EntIndexToEntRef(entity));
	return Plugin_Handled;
}

//#endregion

void SQL_OnConnected(Database db, const char[] error, any data) {
	if (db == null) {
		if (error[0]) LogError("Could not connect to presistend MapProp database: %s", error);
		else LogError("Could not connect to presistend MapProp database: Unknown Error");
		return;
	}
	g_db = db;
	g_dbConnected = true;
	if (!SQL_FastQuery(g_db, "CREATE TABLE IF NOT EXISTS mapprops(map TEXT NOT NULL, model TEXT NOT NULL, owner TEXT NOT NULL, posx REAL NOT NULL, posy REAL NOT NULL, posz REAL NOT NULL, pitch REAL NOT NULL, yaw REAL NOT NULL, roll REAL NOT NULL, color INT NOT NULL) "))
		SetFailState("Could not create mapprops table");
	LoadProps(false);
}

static void LoadProps(bool reload=true) {
	if (g_currentMapName[0]==0) return; //needs to be called by maps start and sql_onconnected

	if (g_dbConnected && g_mapProps.Length == 0 && !reload) {
		char query[1024];
		g_db.Format(query, sizeof(query), "SELECT model,owner,posx,posy,posz,pitch,yaw,roll,color FROM mapprops WHERE map='%s'", g_currentMapName);
		g_db.Query(SQL_OnPropsLoad, query);
	} else {
		for (int index = g_mapProps.Length-1; index >= 0; index -= 1) {
			LocalPropData local;
			g_mapProps.GetArray(index,local);
			local.Restore(index);
		}
	}
}

void SQL_OnPropsLoad(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		if (error[0]) LogError("Could not load map props for %s: %s", g_currentMapName, error);
		else LogError("Could not load map props for %s: Unknown Error", g_currentMapName);
		return;
	}
	g_mapProps.Clear();
	while (results.FetchRow()) {
		LocalPropData local;
		results.FetchString(0, local.model, sizeof(LocalPropData::model));
		results.FetchString(1, local.owner, sizeof(LocalPropData::owner));
		local.origin[0]=results.FetchFloat(2);
		local.origin[1]=results.FetchFloat(3);
		local.origin[2]=results.FetchFloat(4);
		local.rotation[0]=results.FetchFloat(5);
		local.rotation[1]=results.FetchFloat(6);
		local.rotation[2]=results.FetchFloat(7);
		IntToColor(results.FetchInt(8), local.color);
		local.physics = false;
		local.saved = true;
		local.entref = INVALID_ENT_REFERENCE;
		local.Restore(g_mapProps.PushArray(local));
	}
	delete results;
}

void SQL_FastAsync(const char[] query) {
	g_db.Query(__SQL_FastCB, query);
}
public void __SQL_FastCB(Database db, DBResultSet results, const char[] error, any data) {
	if (results == null) {
		PrintToServer("Query failed: %s", error[0]?error:"Unknown");
	}
}

int SpawnPropAt(const char[] model, float origin[3], float angles[3], int skin=0, bool physics=false, Collision_Group_t collisionGroup=COLLISION_GROUP_NONE, int takeDamage=DAMAGE_EVENTS_ONLY) {
	//simple edict protection
	if (!CheckEdictLimit()) return INVALID_ENT_REFERENCE;
	
	int entity;
	if(strlen(model)==0 || !FileExists(model, true) || (entity = CreateEntityByName(physics?"prop_physics_override":"prop_dynamic_override")) == INVALID_ENT_REFERENCE) 
		return INVALID_ENT_REFERENCE;

	if(!IsModelPrecached(model)) {
		PrecacheModel(model);
	}

	char number[4];
	DispatchKeyValueVector(entity, "origin", origin);
	if (!IsNullVector(angles)) DispatchKeyValueVector(entity, "angles", angles);
	DispatchKeyValue(entity, "model", model);
	IntToString(skin, number, sizeof(number));
	DispatchKeyValue(entity, "skin", number);
	IntToString(view_as<int>(collisionGroup), number, sizeof(number));
	DispatchKeyValue(entity, "CollisionGroup", number);
	DispatchKeyValue(entity, "solid", "6"); //VPhysics
	if(DispatchSpawn(entity)) {
		ActivateEntity(entity);
		Entity_SetTakeDamage(entity, takeDamage);
		return entity;
	}
	return INVALID_ENT_REFERENCE;
}

int SpawnOwnedPropAt(const char[] model, const char[] steamid, float position[3], float rotation[3], bool physics, int forceIndex=-1) {
	int entity = SpawnPropAt(model, position, rotation, _, physics, COLLISION_GROUP_PLAYER, _);
	if (entity == INVALID_ENT_REFERENCE) return INVALID_ENT_REFERENCE;

	if (forceIndex >= 0) {
		g_mapProps.Set(forceIndex, EntIndexToEntRef(entity), LocalPropData::entref);
	} else {
		LocalPropData local;
		strcopy(local.model, sizeof(LocalPropData::model), model);
		strcopy(local.owner, sizeof(LocalPropData::owner), steamid);
		local.origin = position;
		local.rotation = rotation;
		local.physics = physics;
		local.color[0] = local.color[1] = local.color[2] = local.color[3] = 255;
		local.saved = false;
		local.entref = EntIndexToEntRef(entity);
		g_mapProps.PushArray(local);
	}
	return entity;
}

int SpawnPropAtClient(int client, const char[] model, bool physics) {
	float origin[3], angles[3];
	GetClientEyePosition(client, origin);
	GetClientAbsAngles(client, angles);
	origin[0] += 64 * Cosine(DegToRad(angles[1]));
	origin[1] += 64 * Sine(DegToRad(angles[1]));
	return SpawnOwnedPropAt(model, g_clientSteamId[client], origin, angles, physics);
}

static bool _HitSelfFilter(int entity, int contentsMask, int caster) {
	return entity != caster;
}

int GetClientViewTarget(int client, bool &didHit = false, float hitPos[3] = {0.0, 0.0, 0.0}, int flags = MASK_SOLID) {
	float pos[3], angles[3];
	GetClientEyePosition(client, pos);
	GetClientEyeAngles(client, angles);
	Handle trace = TR_TraceRayFilterEx(pos, angles, flags, RayType_Infinite, _HitSelfFilter, client);
	int result;
	if(!(result = TR_GetEntityIndex(trace))) { // bypass worldspawn
		result = -1;
	}
	didHit = TR_DidHit(trace);
	TR_GetEndPosition(hitPos, trace);
	delete trace;
	return result;
}

bool GetMapPropByRef(int entref, LocalPropData outData, int& index=0, int importOwner=-1) {
	if (entref > 0) entref = EntIndexToEntRef(entref); //user didn't convert
	if (entref == INVALID_ENT_REFERENCE) return false;
	index = g_mapProps.FindValue(entref, LocalPropData::entref);
	if (index >= 0) {
		g_mapProps.GetArray(index, outData);
		return true;
	} else if (importOwner>=0 && outData.ImportFrom(EntRefToEntIndex(entref), importOwner)) {
		index = g_mapProps.PushArray(outData);
		return true;
	}
	return false;
}

int FindCommandTargetEntity(int client, bool onlyPhysics=false, bool cursorOnly=false) {
	int entity;
	if (GetCmdArgs() == 0 || cursorOnly) {
		entity = GetClientViewTarget(client);
		if (entity == INVALID_ENT_REFERENCE) {
			ReplyToCommand(client, "[SM] Could not find a valid prop at your cursor");
			return INVALID_ENT_REFERENCE;
		}
	} else {
		char arg[12];
		GetCmdArg(1,arg,sizeof(arg));
		int parsed = StringToIntEx(arg, entity, 16);
		if (parsed != strlen(arg)) {
			ReplyToCommand(client, "[SM] The target ref was invalid");
			return INVALID_ENT_REFERENCE;
		}
		entity = EntRefToEntIndex(entity);
	}
	if (entity == INVALID_ENT_REFERENCE) {
		ReplyToCommand(client, "[SM] The target ref was invalid");
		return INVALID_ENT_REFERENCE;
	}
	char classname[64];
	if (!GetEntityClassname(entity, classname, sizeof(classname)) || 
		!(StrContains(classname, "prop_physics")==0 || (StrContains(classname, "prop_dynamic")==0) && !onlyPhysics)) {
		ReplyToCommand(client, "[SM] Target is not a valid prop");
		return INVALID_ENT_REFERENCE;
	}
	return entity;
}

// int ColorToHex(const int rgba[4], char[] hex, int maxsize) {
// 	return Format(hex, maxsize, "%08X", ColorToInt(rgba));
// }
// int HexToColor(const char[] hex, int rgba[4]) {
// 	int l=strlen(hex),c;
// 	if (l != StringToIntEx(hex,c,16)) return 0;
// 	if (l == 6) c = (c<<8)|255;
// 	else if (l != 8) return 0;
// 	IntToColor(c,rgba);
// 	return l;
// }
int ColorToInt(const int rgba[4]) {
	return ((rgba[0]&255)<<24)|((rgba[1]&255)<<16)|((rgba[2]&255)<<8)|(rgba[3]&255);
}
void IntToColor(int color, int rgba[4]) {
	rgba[0] = (color>>24)&255;
	rgba[1] = (color>>16)&255;
	rgba[2] = (color>>8)&255;
	rgba[3] = color&255;
}

int GetClientBySteamId(const char[] steamId) {
	for (int client=1; client<=MaxClients; client++) {
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		if (StrEqual(g_clientSteamId[client], steamId)) return client;
	}
	return 0;
}

int DeleteAllPropsBySteamId(const char[] steamid) {
	int deleted;
	LocalPropData local;
	for (int p=g_mapProps.Length-1; p>=0; p-=1) {
		g_mapProps.GetArray(p, local);
		if (!StrEqual(local.owner, steamid))
			continue;
		local.DropAsync();
		g_mapProps.Erase(p);
		int entity = EntRefToEntIndex(local.entref);
		if (entity != INVALID_ENT_REFERENCE)
			AcceptEntityInput(entity, "Kill");
		deleted += 1;
	}
	return deleted;
}

bool CheckEdictLimit() {
	//calculate the base headroom
	int space = GetMaxEntities() - GetEntityCount();
	//we probably want to spawn one and keep some extra buffer, 
	// and we don't want to run into the lowedict action
	// so subtract some small value
	space -= ( g_iEdictBuffer + 12 );
	return space > 0;
}