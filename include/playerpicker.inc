/** example usage:
void ThenKickPlayer(int client) {
	if (client <= 0)
		//if you want a more specific error reply, check ReplyToTargetError
		PrintToChat(client, "This target is no longer valid");
	else
		KickClient(client, "Kicked by admin");
}
void Command_Kick(int client, int argc) {
	char pattern[128];
	GetCmdArgString(pattern, sizeof(pattern));
	int targets[MAXPLAYERS];
	char namebuf[32];
	bool tn_is_ml;
	int results = ProcessTargetString(pattern, client, targets, MAXPLAYERS, COMMAND_FILTER_NO_BOTS, namebuf, sizeof(namebuf), tn_is_ml);
	if (results < 0) {
		ReplyToTargetError(results);
	} else if (results == 0) {
		PickPlayer(client, COMMAND_FILTER_NO_BOTS, ThenKickPlayer);
	} else for (int i=0; i<results; i++) {
		KickPlayer(targets[i], "Kicked by admin");
	}
}
void OnClientDisconnect(int client) {
	CancelPlayerPick(client);
}
*/

//#pragma once
#if defined __PLAYER_PICKER
#endinput
#endif
#define __PLAYER_PICKER

// includes
#include <sourcemod>

//we do new decls, semicolon
#pragma newdecls required
#pragma semicolon 1

#define COMMAND_TARGET_CANCELLED 0

//callbacks
typeset ClientPickedCB {
	/**
	 * Callend when the Pick Player menu is gone. Client can have one of the following values:
	 * - COMMAND_TARGET_CANCELLED : The menu was cancelled
	 * - COMMAND_TARGET_NONE : The selected player disconnected while the menu was opened
	 * - COMMAND_TARGET_NOT_ALIVE : The player died since the menu was opened
	 * - COMMAND_TARGET_NOT_DEAD : The player respawned since the menu was opened
	 * - COMMAND_TARGET_NOT_IN_GAME : The player has disconnected (repurposed)
	 * - COMMAND_TARGET_NOT_HUMAN : The player selected was a bot
	 * - any other value : client index of the target
	 * 
	 * @param client - the result
	 * @noreturn
	 */
	function void(int client);
	/**
	 * Callend when the Pick Player menu is gone. Client can have one of the following values:
	 * - COMMAND_TARGET_CANCELLED : The menu was cancelled
	 * - COMMAND_TARGET_NONE : The selected player disconnected while the menu was opened
	 * - COMMAND_TARGET_NOT_ALIVE : The player died since the menu was opened
	 * - COMMAND_TARGET_NOT_DEAD : The player respawned since the menu was opened
	 * - COMMAND_TARGET_NOT_IN_GAME : The player has disconnected (repurposed)
	 * - COMMAND_TARGET_NOT_HUMAN : The player selected was a bot
	 * - any other value : client index of the target
	 * 
	 * @param client - the result
	 * @param data - the data passed in to PickPlayer
	 * @noreturn
	 */
	function void(int client, any data);
}
static ClientPickedCB callbacks[MAXPLAYERS+1];
static Menu menus[MAXPLAYERS+1];
static any addedData[MAXPLAYERS+1];
static int filter[MAXPLAYERS+1]; //post validation

stock void CancelPlayerPick(int client) {
	if (menus[client]==null) return;
	Menu menu = menus[client];
	menus[client] = null;
	CancelMenu(menu);
}

/**
 * Display a pick player menu. Command Filters flags are recycled to filter the displayed options.
 * Once the client selects another player or if the menu cancelles, the then callback will be called.
 * You can pass any data along to the callback, make sure to close if it's a Handle!
 * 
 * @param client - the player to display the menu to
 * @param commandFilterFlags - one of COMMAND_FILTER_ALIVE, COMMAND_FILTER_DEAD, COMMAND_FILTER_CONNECTED, COMMAND_FILTER_NO_BOTS from commandfilters.inc
 * @param then - the callback after selection is done
 * @param data - optional pass-along to callback
 * @noreturn
 */
stock void PickPlayer(int client, int commandFilterFlags, ClientPickedCB then, any data=0) {
	if ((commandFilterFlags & (COMMAND_FILTER_ALIVE|COMMAND_FILTER_DEAD)) == (COMMAND_FILTER_ALIVE|COMMAND_FILTER_DEAD)) {
		ThrowError("Invalid flags combination, can't require players to be dead and alive");
	}
	if (menus[client]!=null) {
		Menu menu = menus[client];
		menus[client] = null;
		CancelMenu(menu);
	}
	addedData[client] = data;
	callbacks[client] = then;
	filter[client] = commandFilterFlags;
	Menu menu = menus[client] = new Menu(__OnClientPickMenuHandler);
	//build title
	char title[128];
	title = "Pick Player";
	if (commandFilterFlags != 0) {
		StrCat(title, sizeof(title), " (");
		bool more;
		if (commandFilterFlags & COMMAND_FILTER_ALIVE) {
			StrCat(title, sizeof(title), "Alive Only");
			more=true;
		}
		if (commandFilterFlags & COMMAND_FILTER_DEAD) {
			if (more) StrCat(title, sizeof(title), ", ");
			StrCat(title, sizeof(title), "Dead Only");
			more = true;
		}
		if (commandFilterFlags & COMMAND_FILTER_CONNECTED) {
			if (more) StrCat(title, sizeof(title), ", ");
			StrCat(title, sizeof(title), "Allows Connecting");
			more = true;
		}
		if (commandFilterFlags & COMMAND_FILTER_NO_BOTS) {
			if (more) StrCat(title, sizeof(title), ", ");
			StrCat(title, sizeof(title), "No Bots");
		}
		StrCat(title, sizeof(title), ")");
	}
	menu.SetTitle(title);
	//collect targets
	for (int target=1; target<=MaxClients; target++) {
		if (!IsClientConnected(target)) continue;
		//require ingame player?
		if (!(commandFilterFlags & COMMAND_FILTER_CONNECTED) && !IsClientInGame(target)) continue;
		//filter dead or alive
		if ((commandFilterFlags & COMMAND_FILTER_ALIVE) && !IsPlayerAlive(target)) continue;
		if ((commandFilterFlags & COMMAND_FILTER_DEAD) && IsPlayerAlive(target)) continue;
		//filter bots
		if ((commandFilterFlags & COMMAND_FILTER_NO_BOTS) && IsFakeClient(target)) continue;
		//add entry
		char info[8], name[48];
		Format(info, sizeof(info), "%i", GetClientUserId(target));
		Format(name, sizeof(name), "%N", target);
		menu.AddItem(info, name);
	}
	menu.Display(client, MENU_TIME_FOREVER);
}

public int __OnClientPickMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
	if (action == MenuAction_Select) {
		char info[8];
		menu.GetItem(param2, info, sizeof(info));
		int target = GetClientOfUserId(StringToInt(info));
		if (target) {
			//require connected player? (should be impossible - state generally cannot revert)
			if (!(filter[param1] & COMMAND_FILTER_CONNECTED) && !IsClientInGame(target)) target = COMMAND_TARGET_NOT_IN_GAME;
			//filter dead or alive
			else if ((filter[param1] & COMMAND_FILTER_ALIVE) && !IsPlayerAlive(target)) target = COMMAND_TARGET_NOT_ALIVE;
			else if ((filter[param1] & COMMAND_FILTER_DEAD) && IsPlayerAlive(target)) target = COMMAND_TARGET_NOT_DEAD;
			//filter bots (should be impossible)
			else if ((filter[param1] & COMMAND_FILTER_NO_BOTS) && IsFakeClient(target)) target = COMMAND_TARGET_NOT_HUMAN;
		} else target = COMMAND_TARGET_NOT_IN_GAME;
		menus[param1] = null;
		Call_StartFunction(INVALID_HANDLE, callbacks[param1]);
		callbacks[param1] = INVALID_FUNCTION;
		Call_PushCell(target);//0 for invalid target/target changed < 0 for other error?
		Call_PushCell(addedData[param1]);
		addedData[param1] = 0;
		Call_Finish();
	} else if (action == MenuAction_Cancel) {
		menus[param1] = null;
		Call_StartFunction(INVALID_HANDLE, callbacks[param1]);
		callbacks[param1] = INVALID_FUNCTION;
		Call_PushCell(0);//0 for no client selected
		Call_PushCell(addedData[param1]);
		addedData[param1] = 0;
		Call_Finish();
	} else if (action == MenuAction_End) {
		delete menu;
	}
}

//as we're a header, reset for legacy headers that might come after us
#pragma newdecls optional
#pragma semicolon 0