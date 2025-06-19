#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#include <sourcecomms>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "24w03a"

public Plugin myinfo = {
	name = "Name Checker",
	author = "reBane",
	description = "Please use distinct names",
	version = PLUGIN_VERSION,
	url = "N/A"
}

#define NAME_MAX_LENGTH 32

ArrayList clientNGrams[MAXPLAYERS+1];
bool clientPunished[MAXPLAYERS+1];
ConVar cvar_similarity;

public void OnPluginStart() {
	HookEvent("player_changename", OnPlayerChangeName, EventHookMode_Post);
	HookEvent("player_spawn", OnPlayerSpawn, EventHookMode_Post);
	
	RegAdminCmd("sm_freename", Cmd_FreeName, ADMFLAG_GENERIC, "Re-enable comms for everyone currently blocked due to renames");
	
	cvar_similarity = CreateConVar("sv_max_name_similarity", "0.66", "If names are more similar than this, comms get blocked (0.5 .. 1.0)", FCVAR_DONTRECORD, true, 0.5, true, 1.0);
	
	AddMultiTargetFilter("@deceivers", TargetCollector_Punished, "Duped Names", false);
	AddMultiTargetFilter("@dupednames", TargetCollector_Punished, "Duped Names", false);
	AddMultiTargetFilter("@namestealer", TargetCollector_Punished, "Name-Stealers", false);
	AddMultiTargetFilter("@!deceivers", TargetCollector_Punished, "Uniquely Named", false);
	AddMultiTargetFilter("@!dupednames", TargetCollector_Punished, "Uniquely Named", false);
	AddMultiTargetFilter("@!namestealer", TargetCollector_Punished, "Uniquely Named", false);
	
	char name[NAME_MAX_LENGTH];
	for (int client=1; client<MaxClients; client++) {
		if (IsClientInGame(client) && GetClientName(client, name, sizeof(name))) {
			CreatePlayerNGram(client, name);
		}
	}
}

public Action Cmd_FreeName(int client, int args) {
	for (int target=1; target<MaxClients; target++) {
		if (IsClientInGame(target)) {
			FreenameClient(target);
		}
	}
	ShowActivity(client, "%L re-enabled comms for clients with similar names", client);
	return Plugin_Handled;
}


public void OnClientDisconnect(int client) {
	if (clientNGrams[client] != null) {
		clientNGrams[client].Clear();
	}
	clientPunished[client] = false;
}

public void OnClientPutInServer(int client) {
	ValidateNamechange(client);
}

public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client) return;
	
	if (clientPunished[client] && GetClientTeam(client)>1) //ignore before assigned a team
		ValidateNamechange(client, false); 
}

public void OnPlayerChangeName(Event event, const char[] name, bool dontBroadcast) {
	char newName[32];
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client) return;
	event.GetString("newname", newName, sizeof(newName));
	
	RequestFrame(ValidateNamechangeDelayed, GetClientUserId(client));
}

void ValidateNamechangeDelayed(int userid) {
	int client = GetClientOfUserId(userid);
	if (client) ValidateNamechange(client);
}

public bool TargetCollector_Punished(const char[] pattern, ArrayList clients, int client) {
	bool collectPunished = StrContains(pattern, "!") == -1;
	for(int target = 1; target <= MaxClients; target += 1) {
		if (IsClientInGame(target) && clientPunished[client] == collectPunished)
			clients.Push(target);
	}
	return true;
}


bool ValidateNamechange(int client, bool updateName=true) {
	if (updateName) {
		char name[NAME_MAX_LENGTH];
		if (!GetClientName(client, name, sizeof(name))) return false; //?
		
		CreatePlayerNGram(client, name);
	}
	
	//bypass
	if (IsFakeClient(client) || IsClientSourceTV(client) || IsClientReplay(client)) return true; // bots can have it whatever
	if (CheckCommandAccess(client, "sm_rename", ADMFLAG_GENERIC)) return true;
	
	//find similar names
	float similarity = cvar_similarity.FloatValue;
	int similar = FindPlayerWithSimilarName(client, similarity);
	if (similar)
		PunishClient(client, similar, similarity);
	else
		FreenameClient(client);
	return similar == 0; //name is OK
}

void PunishClient(int client, int similar, float similarity) {
	PrintToChat(client, "[SM] Your name is too close to %N (%.0f%%)", similar, similarity*100);
	PrintToChat(client, "[SM]  -> Comms are disabled until you rename");
	
	if (clientPunished[client]) return;
	
	// new block, notify staff
	char buf[32];
	FormatActivitySource(0, client, buf, sizeof(buf));
	ShowActivity(0, "[SM] The comms for %L were blocked, name is too close to %L (%.0f%%)", client, similar, similarity*100);
	
	if (SourceComms_GetClientGagType(client) == bNot)
		SourceComms_SetClientGag(client, true, -1, false, "Duplicate Name");
	if (SourceComms_GetClientMuteType(client) == bNot)
		SourceComms_SetClientMute(client, true, -1, false, "Duplicate Name");
	
	clientPunished[client] = true;
}

void FreenameClient(int client) {
	if (!clientPunished[client]) return;
	
	PrintToChat(client, "[SM] Comms are re-enabled");
	
	if (SourceComms_GetClientGagType(client) == bSess)
		SourceComms_SetClientGag(client, false);
	if (SourceComms_GetClientMuteType(client) == bSess)
		SourceComms_SetClientMute(client, false);
	
	clientPunished[client] = false;
}

/**
 * Find a player with a name similarity of at least the specified value.
 * The client with the most similar name will be returned and the similarity
 * value will be updated with the actual similarity.
 * Returns the client index or 0 if no client was found.
 */
int FindPlayerWithSimilarName(int searchClient, float& similarity) {
	int found;
	for (int client=1; client<=MaxClients; client+=1) {
		if (!IsClientInGame(client) || IsFakeClient(client) || IsClientSourceTV(client) || IsClientReplay(client)) continue;
		if (client==searchClient) continue;
		float value = NGramSimilarity(clientNGrams[client], clientNGrams[searchClient]);
//		if (value) PrintToChatAll("Name similarity with %i (%.0f%%)", client, value*100);
		if (value >= similarity) {
			similarity = value;
			found = client;
		}
	}
	return found;
}

float NGramSimilarity(ArrayList a, ArrayList b) {
	//one list is invalid
	if (a == null || b == null || a.Length == 0 || b.Length == 0) return 0.0;
	//only count the theoretical size of these sets, as we dont need the elements
	int inters = b.Length;
	int unions = 0;
	for (int i=a.Length-1; i>=0; i-=1) {
		int value = a.Get(i);
		bool isAinB = b.FindValue(value) != -1;
		if (isAinB) unions += 1; //in both lists, increases the size of a union
		else inters += 1; //new value that would increase size of an intersection
	}
//	PrintToChatAll("Left: %i, Right: %i, Union: %i, Intersect: %i", a.Length, b.Length, unions, inters);
	return float(unions)/float(inters); //similarity of trigrams in a and b
}

void CreatePlayerNGram(int client, const char[] inname) {
	//prepare list
	if (clientNGrams[client] == null) {
		clientNGrams[client] = new ArrayList();
	} else {
		clientNGrams[client].Clear();
	}
	ArrayList list = clientNGrams[client];
	//try to remove engine duplicate suffix, scan right to left
	char name[NAME_MAX_LENGTH];
	
	int len = strlen(inname);
	if (len == 0) return; //?
	int idx = 0;
	bool skipprefix = false;
	if (len > 3 && inname[idx] == '(') {
		do { idx += 1; }
		while (idx < len && inname[idx] >= '0' && inname[idx] <= '9');
		if (idx+1 < len && inname[idx] == ')') {
			idx += 1;
			skipprefix = true;
		}
	}
	//make a copy of name without "duplicate number prefix" or spaces
	if (!skipprefix) idx = 0;
	int cpyidx = 0;
	for (; idx < len;) {
		if (inname[idx] <= 32) { idx++; continue; }// ignore spaces and control chars
		if (inname[idx] < 128) { name[cpyidx++] = inname[idx++]; }
		//construct utf8-char
		int codepoint;
		int width = getCodepoint(inname[idx], codepoint);
		if (isMBSpace(codepoint)) { idx += width; }
		else while (width-->0) { name[cpyidx++] = inname[idx++]; }
	}
	name[cpyidx] = 0;
	//create ngrams, i'll use trigrams as that fits a cell
	// im using bi-grams are names are short. int would work for up to 4-grams
	
	len = strlen(name);
	if (len == 0) { name=" "; len=1; } //we need something, if all space, use space
	int gram = 0;
	for (int i=0; i<len; i+=1) {
		char c = name[i];
		if (c >= 'A' && c <= 'Z') c|=' '; //ignore ascii case
		gram = ((gram << 8) & 0x0000FF00) | (c);
		list.Push(gram);
	}
	//for a ngram size 3, we need to push 2 more entries
	gram = ((gram << 8) & 0x0000FF00);
	list.Push(gram);
	//sort for and remove duplicates
	list.Sort(Sort_Ascending, Sort_Integer);
	for (int i=list.Length-1; i>1; i-=1) {
		if (list.Get(i-1) == list.Get(i))
			list.Erase(i);
	}
//	PrintToChatAll("NGram size for %s: %i", name, list.Length);
//	for (int i=0;i<list.Length;i++) {
//		PrintToChatAll("  %04X", list.Get(i));
//	}
}

bool isMBSpace(int codepoint) {
	switch(codepoint) {
		case 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 
		     0x2007, 0x2008, 0x2009, 0x200A, 0x200B, 0x200C, 0x200D, 0x202f, 0x205f, 0x3000:
			return true;
		default:
			return false;
	}
}

int getCodepoint(const char[] string, int& codepoint) {
	if (string[0] < 128) { codepoint = string[0]; return 1; } //ASCII
	int bytes=0;
	if ((string[0] & 0xe0) == 0xc0) { bytes = 2; codepoint = string[0]&0x1f; }
	else if ((string[0] & 0xf0) == 0xe0) { bytes = 3; codepoint = string[0]&0x0f; }
	else if ((string[0] & 0xf8) == 0xf0) { bytes = 4; codepoint = string[0]&0x07; }
	else { codepoint = string[0]; return 1; } //broken, ignore
	for (int c=1; c<bytes; c++) {
		if ((string[0] & 0xc0) != 0x80) { codepoint = string[0]; return 1; } //broken, ignore
		codepoint = (codepoint << 6) | (string[c] & 0x3f);
	}
	return bytes;
}
