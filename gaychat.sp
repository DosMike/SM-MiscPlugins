#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <metachatprocessor>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "25w22a"

public Plugin myinfo = {
	name = "Proud Chat",
	author = "reBane",
	description = "It be June",
	version = PLUGIN_VERSION,
	url = "N/A"
}

public void OnPluginStart()
{
    MCP_HookChatMessage(OnChat, mcpHookLate);
}

//https://huey.design/
#define NUM_COLORS 20
char rainbow[NUM_COLORS][8] = {
    "\x07;ffc0c0",
    "\x07;ffd2c1",
    "\x07;ffe5c2",
    "\x07;fff8c4",
    "\x07;f2ffc4",
    "\x07;e0ffc4",
    "\x07;ceffc4",
    "\x07;c4ffc9",
    "\x07;c4ffda",
    "\x07;c4ffec",
    "\x07;c4ffff",
    "\x07;c2ebff",
    "\x07;c0d8ff",
    "\x07;bfc5ff",
    "\x07;cabeff",
    "\x07;ddbfff",
    "\x07;f2c0ff",
    "\x07;ffc0f8",
    "\x07;ffc0e4",
    "\x07;ffc0d1",
};
int first = 0;

Action OnChat(int& sender, ArrayList recipients, mcpSenderFlag& senderflags, mcpTargetGroup& targetgroup, mcpMessageOption& options, char[] targetgroupColor, char[] name, char[] message)
{
    int len = strlen(message); // max color steps
    int colorCapacity = (128 - len) / 7; // max amount of colors we can squeeze
    if (colorCapacity == 0) return Plugin_Continue;
    //figure out how many colors we want to add
    int inserts = len < colorCapacity ? len : colorCapacity;
    if (inserts > NUM_COLORS) inserts = NUM_COLORS;

    char buffer[130];

    if (inserts <= 3) {
        FormatEx(buffer, sizeof(buffer), "%s%s", rainbow[GetRandomInt(0,19)], message);
    } else {
        int charStep = RoundToCeil(float(len) / float(inserts));
        int outOffset = 0;
        int capacity = sizeof(buffer);
        int color = first;
        int msgOffset = 0;
        for (int i; i<inserts && msgOffset < len; i++) {
            strcopy(buffer[outOffset], capacity, rainbow[color]);
            color = (color + 1)%NUM_COLORS;
            outOffset += 7;
            capacity -= 7;
            strcopy(buffer[outOffset], charStep+1, message[msgOffset]);
            msgOffset += charStep;
            outOffset += charStep;
            capacity -= charStep;
            // unicode handling lol
            while ((message[msgOffset] & 0x80)!=0) {
                buffer[outOffset++] = message[msgOffset++];
                capacity --;
            }
        }
    }
    strcopy(message, MCP_MAXLENGTH_INPUT, buffer);
    options &=~ mcpMsgRemoveColors;
    first = (first+GetRandomInt(1,5))%NUM_COLORS;
    return Plugin_Changed;
}