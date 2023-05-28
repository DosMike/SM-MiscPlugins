/** Example Plugin */

#include <sourcemod>

#include "smrcon.inc"
#include "SteamWorks.inc"

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "23w21a"

public Plugin myinfo = {
	name = "Staff RCon",
	author = "reBane",
	description = "Limit RCon to staff",
	version = PLUGIN_VERSION,
	url = "N/A"
};

char clientAddr[MAXPLAYERS+1][24];
ArrayList ipWhitelist = null;

public void OnPluginStart()
{
	ipWhitelist = new ArrayList(ByteCountToCells(24));
	// add auto self addresses
	int addr[4];
	if (SteamWorks_GetPublicIP(addr)) {
		// the actual public ip
		char buffer[24];
		FormatEx(buffer, sizeof(buffer), "%d.%d.%d.%d", addr[0], addr[1], addr[2], addr[3]);
		ipWhitelist.PushString(buffer);
	}
	ConVar cvar = FindConVar("hostip");
	if (cvar != null) {
		char buffer[24];
		// this might be the interface/lan ip
		addr[0] = cvar.IntValue;
		FormatEx(buffer, sizeof(buffer), "%d.%d.%d.%d", (addr[0]>>24) & 0xff, (addr[0]>>16) & 0xff, (addr[0]>>8) & 0xff, (addr[0]) & 0xff);
		ipWhitelist.PushString(buffer);
	}
	ipWhitelist.PushString("127.0.0.1"); // local host is local :)
	// add all IP adds that are allowed to access without being the ip of a
	// staff member. This is important for system queries like SourceBans.
	ipWhitelist.PushString("72.5.53.28");
	
}


public void OnClientAuthorized(int client, const char[] auth)
{
	if (!GetClientIP(client, clientAddr[client], sizeof(clientAddr[])))
		clientAddr[client] = "INVALID";
}
public void OnClientDisconnect(int client)
{
	clientAddr[client] = "";
}
int GetClientByIPAddr(const char[] addr) {
	for (int client=1; client<=MaxClients; client++) {
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		if (StrEqual(clientAddr[client], addr)) return client;
	}
	return 0;
}

public Action SMRCon_OnAuth(int rconId, const char[] address, const char[] password, bool &allow)
{
	if (!allow) //wrong password -> go away
		return Plugin_Continue;
	
	if (ipWhitelist.FindString(address) >= 0) //on whitelist -> continue
	{	PrintToServer("RCON from %s on whitelist", address);
		return Plugin_Continue;
	}
	int client = GetClientByIPAddr(address);
	PrintToServer("RCON %i %s associated to client %i", rconId, address, client);
	if (!client) // ip not from a player -> go away
	{	PrintToServer("RCON %i from %s is not on the server", rconId, address);
		allow = false;
		return Plugin_Changed;
	}
	if (CheckCommandAccess(client, "sm_rcon", ADMFLAG_RCON))
	{	PrintToServer("RCON %i from %s (%N) has no rcon access", rconId, address, client);
		BanClient(client, 0, BANFLAG_AUTO, "Unauthorized RCON access", "Rcon Hacking", "rcon");
		allow = false;
		return Plugin_Changed;
	}
	return Plugin_Continue;
}


