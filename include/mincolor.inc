#if defined __REBANE_STOCK_CHATCOLORS_H__
#endinput
#endif
#define __REBANE_STOCK_CHATCOLORS_H__

// ===== Minimal Color Stocks =====

static int g_colorClient=-1;
/// Set this value to a client as ref for \x03. Valid for one call. Resets to -1 for recipient/console
stock void CNextColorSource(int client=-1){ g_colorClient=client; }
stock void CPrintToChat(int client, const char[] format, any...) {
	char buffer[256];
	VFormat(buffer[1], sizeof(buffer)-1, format, 3);
	buffer[0]=1;
	if (g_colorClient < 0) g_colorClient=client;
	
	Handle msg = StartMessageOne("SayText2", client, USERMSG_RELIABLE | USERMSG_BLOCKHOOKS);
	if (msg == INVALID_HANDLE) { PrintToChat(client, "%s", buffer); return; }
	BfWrite buf = UserMessageToBfWrite(msg);
	buf.WriteByte(g_colorClient);
	buf.WriteByte(false);
	buf.WriteString(buffer);
	EndMessage();
	
	g_colorClient=-1;
}
stock void CPrintToChatAll(const char[] format, any...) {
	char buffer[256];
	VFormat(buffer[1], sizeof(buffer)-1, format, 2);
	buffer[0]=1;
	if (g_colorClient < 0) g_colorClient=0;
	
	Handle msg = StartMessageAll("SayText2", USERMSG_RELIABLE | USERMSG_BLOCKHOOKS);
	if (msg == INVALID_HANDLE) { PrintToChatAll("%s", buffer); return; }
	BfWrite buf = UserMessageToBfWrite(msg);
	buf.WriteByte(g_colorClient);
	buf.WriteByte(false);
	buf.WriteString(buffer);
	EndMessage();
	
	g_colorClient=-1;
}