#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <tf2_stocks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "23w42c"

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

Menu menuList[3];
int clientVoiceMenu[MAXPLAYERS+1];
float clientLastVoiceTime[MAXPLAYERS+1];
int clientPrevButtons[MAXPLAYERS+1];

bool clientSpectating[MAXPLAYERS+1] = {false, ...};
int clientGhostRef[MAXPLAYERS+1] = {-1, ...};
int clientOldTeam[MAXPLAYERS+1] = {0, ...};
int clientOldClass[MAXPLAYERS+1] = {0, ...};
ConVar cvarEnableVoice;
ConVar cvarAllowPlayerUse;

public void OnPluginStart() {
    HookEventEx("player_team", OnPlayerChangeTeam, EventHookMode_Post);
    HookEventEx("player_changeclass", OnPlayerChangeClass, EventHookMode_Post);
    
    // fake voice menus
    AddCommandListener(OnVoiceCmd, "voicemenu");
    RegConsoleCmd("sm_voicemenu", OnVoiceMenu, "Sourcemod proxy for 'voice_menu_x' and 'voicemenu x y'");
    cvarEnableVoice = CreateConVar("specghost_voicemenu_enabled", "1", "Enable specator ghost voicemenu (sm_voicemenu)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    cvarAllowPlayerUse = FindConVar("tf_allow_player_use");
    for (int i=1; i<=MAXPLAYERS; i++) clientGhostRef[i] = INVALID_ENT_REFERENCE;

    //late load stuff
    for (int client=1; client <= MaxClients; client++) {
        if (IsClientInGame(client)) {
            clientOldTeam[client] = GetClientTeam(client);
            if (clientOldTeam[client] > 1) {
                clientOldClass[client] = view_as<int>(TF2_GetPlayerClass(client));
            } else {
                clientOldClass[client] = GetEntProp(client, Prop_Send, "m_iDesiredPlayerClass");
            }
        }
    }
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

void OnPlayerChangeClass(Event event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client || clientSpectating[client]) return;
    int class = event.GetInt("class");
    clientOldClass[client] = class;
}

public void OnClientConnected(int client) {
    clientOldTeam[client] = 0;
    clientOldClass[client] = GetRandomInt(1,9);
    clientGhostRef[client] = INVALID_ENT_REFERENCE;
    clientSpectating[client] = false;
    clientPrevButtons[client] = 0;
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
    if (!yes && clientGhostRef[client] != INVALID_ENT_REFERENCE) 
        DeleteGhost(client);
}

void CheckGhost(int client) {
    if (!clientSpectating[client]) return;
    ObserverMode mode = view_as<ObserverMode>(GetEntProp(client, Prop_Send, "m_iObserverMode"));
    bool shouldGhost = (mode == OBS_MODE_ROAMING);
    if (clientGhostRef[client] != INVALID_ENT_REFERENCE && !CheckEntRef(clientGhostRef[client]))
        clientGhostRef[client] = INVALID_ENT_REFERENCE;
    bool stateOk = shouldGhost == (clientGhostRef[client] != INVALID_ENT_REFERENCE);
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
        int ghost = EntRefToEntIndex(clientGhostRef[client]);
        TeleportEntity(ghost, pos, ang, NULL_VECTOR);
        SetEntPropFloat(ghost, Prop_Data, "m_flSimulationTime", GetGameTime());
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
    clientGhostRef[client] = EntIndexToEntRef(entity);
}

void DeleteGhost(int client) {
    int ghost = EntRefToEntIndex(clientGhostRef[client]);
    if (ghost != INVALID_ENT_REFERENCE) {
        AcceptEntityInput(ghost, "kill");
        clientGhostRef[client] = INVALID_ENT_REFERENCE;
    }
}

public void OnGameFrame() {
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsClientInGame(client)) continue;
        CheckGhost(client);
    }
}

// re enable features in spectate: voicemenu

char voicecmd_name_class[10][10] = {
    "Unknown",
    "Scout",
	"Sniper",
	"Soldier",
	"Demoman",
	"Medic",
	"Heavy",
	"Pyro",
	"Spy",
	"Engineer"
};
char voicecmd_group_lines[24][22] = {
    "Medic",
    "Thanks",
    "Go",
    "MoveUp",
    "HeadLeft",
    "HeadRight",
    "Yes",
    "No",

    "Incoming",
    "CloakedSpy",
    "SentryAhead",
    "NeedTeleporter",
    "NeedDispenser",
    "NeedSentry",
    "ActivateCharge",
    "", //medic only

    "HelpMe",
    "BattleCry",
    "Cheers",
    "Jeers",
    "PositiveVocalization",
    "NegativeVocalization",
    "NiceShot",
    "GoodJob"
};
int voicecmd_variants[10][24] = {
    {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, // unknown
    {3, 2, 4, 3, 3, 3, 3, 3, 3, 4, 3, 1, 1, 1, 3, 0, 4, 5, 6,12, 5, 5, 3, 4}, // scout
    {2, 2, 3, 2, 3, 3, 3, 4, 4, 3, 1, 1, 1, 1, 4, 0, 3, 6, 8, 8,10, 9, 3, 3}, // sniper
    {3, 2, 3, 3, 3, 3, 4, 3, 1, 3, 3, 1, 1, 1, 3, 0, 3, 6, 6,12, 5, 6, 3, 3}, // soldier
    {3, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 3, 0, 3, 7, 8,11, 5, 6, 3, 2}, // demo
    {3, 2, 4, 2, 3, 3, 3, 3, 3, 2, 2, 1, 1, 1, 3, 0, 3, 6, 6,12, 6, 7, 2, 3}, // medic
    {3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 2, 1, 1, 1, 4, 0, 3, 6, 8, 9, 5, 6, 3, 4}, // hoovy
    {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 2, 1, 2, 1, 1, 1, 1}, // pyro
    {3, 3, 3, 2, 3, 3, 3, 3, 3, 4, 2, 1, 1, 1, 3, 0, 3, 4, 8, 6, 5, 9, 3, 3}, // spy
    {3, 1, 3, 1, 2, 3, 3, 3, 3, 3, 2, 2, 1, 1, 3, 0, 3, 7, 7, 4, 1,12, 3, 3}, // engi
};
void PlayVoiceCmdLine(int player, int class, int group, int line) {
    if (GetGameTime() - clientLastVoiceTime[player] < 5.0) return;
    clientLastVoiceTime[player] = GetGameTime();

    float position[3];
    GetClientEyePosition(player, position);

    if (!(0<=group<=2) || !(0<=line<=7) || !(0<=class<=9)) return; //invalid combo
    int index = group * 8 + line;
    int rng = voicecmd_variants[class][index];
    if (!rng) return; //no line for combo
    rng = GetRandomInt(1, rng);
    char gameSound[36];
    FormatEx(gameSound, sizeof(gameSound), "%s.%s%02d", voicecmd_name_class[class], voicecmd_group_lines[index], rng);
    
    int clientCount;
    int clients[MAXPLAYERS];
    for (int i=1; i<=MaxClients; i++) if (IsClientInGame(i) && GetClientTeam(i)) { clients[clientCount]=i; clientCount++; }
    if (clientCount==0) return; //no targets

    int channel;
    int level;
    float volume;
    int pitch;
    char sample[PLATFORM_MAX_PATH];
    
    if (GetGameSoundParams(gameSound, channel, level, volume, pitch, sample, sizeof(sample), player)) {
        volume  *= 0.5;
        pitch += 50;
        EmitSound(clients, clientCount, sample, player, channel, level, SND_CHANGEPITCH|SND_CHANGEVOL, volume, pitch, -1, position);
    }
}

Action OnVoiceCmd(int client, const char[] command, int argc) {
    if (argc != 2 || !cvarEnableVoice.BoolValue) return Plugin_Continue;
    int group = GetCmdArgInt(1);
    int line = GetCmdArgInt(2);

    if (!CheckEntRef(clientGhostRef[client])) return Plugin_Continue;

    PlayVoiceCmdLine(client, clientOldClass[client], group, line);
    return Plugin_Continue;
}
Action OnVoiceMenu(int client, int argc) {
    if (!cvarEnableVoice.BoolValue) return Plugin_Continue;
    int group, line;
    if (argc >= 1)
        group = GetCmdArgInt(1)-1;
    if (argc >= 2)
        line = GetCmdArgInt(2)-1;
    if (argc == 0) {
        ReplyToCommand(client, "Usage: 'sm_voicemenu X' to act like 'voice_menu_X' or 'sm_voicemenu X Y' to act like 'voicemenu X Y'. Numbers in sm_voicemenu are one higher!");
    } else if (!(0<=group<=2)) {
        ReplyToCommand(client, "Invalid group number (use 1 through 3)");
    } else if (argc == 1) {
        ShowVoiceMenu(client, group);
    } else if (!(0<=line<=7)) {
        ReplyToCommand(client, "Invalid line number (use 1 through 8)");
    } else if (GetClientTeam(client) > 1) {
        FakeClientCommand(client, "voicemenu %d %d", group, line);
    } else if (!CheckEntRef(clientGhostRef[client])) {
        ReplyToCommand(client, "You are currently not a ghost");
    } else {
        PlayVoiceCmdLine(client, clientOldClass[client], group, line);
        return Plugin_Continue;
    }
    return Plugin_Continue;
}

void ShowVoiceMenu(int client, int menu) {
    if (menuList[0] == null) {
        menuList[0] = CreateMenu(CustomVoiceMenuHandler);
        menuList[0].AddItem("00", "MEDIC!");
        menuList[0].AddItem("01", "Thanks!");
        menuList[0].AddItem("02", "Go! Go! Go!");
        menuList[0].AddItem("03", "Move Up!");
        menuList[0].AddItem("04", "Go Left");
        menuList[0].AddItem("05", "Go Right");
        menuList[0].AddItem("06", "Yes");
        menuList[0].AddItem("07", "No");
        menuList[0].Pagination = MENU_NO_PAGINATION;
        menuList[0].ExitButton = true;
        menuList[0].OptionFlags |= MENUFLAG_NO_SOUND;
        menuList[1] = CreateMenu(CustomVoiceMenuHandler);
        menuList[1].AddItem("08", "Incoming");
        menuList[1].AddItem("09", "Spy!");
        menuList[1].AddItem("10", "Sentry Ahead!");
        menuList[1].AddItem("11", "Teleporter Here");
        menuList[1].AddItem("12", "Dispenser Here");
        menuList[1].AddItem("13", "Sentry Here");
        menuList[1].AddItem("14", "Activate Charge!");
        menuList[1].Pagination = MENU_NO_PAGINATION;
        menuList[1].ExitButton = true;
        menuList[1].OptionFlags |= MENUFLAG_NO_SOUND;
        menuList[2] = CreateMenu(CustomVoiceMenuHandler);
        menuList[2].AddItem("16", "HELP!");
        menuList[2].AddItem("17", "Battle Cry");
        menuList[2].AddItem("18", "Cheers");
        menuList[2].AddItem("19", "Jeers");
        menuList[2].AddItem("20", "Positive");
        menuList[2].AddItem("21", "Negative");
        menuList[2].AddItem("22", "Nice Shot");
        menuList[2].AddItem("23", "Good Job");
        menuList[2].Pagination = MENU_NO_PAGINATION;
        menuList[2].ExitButton = true;
        menuList[2].OptionFlags |= MENUFLAG_NO_SOUND;
    }
    clientVoiceMenu[client] = menu+1;
    menuList[menu].Display(client, 5);
}
int CustomVoiceMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action==MenuAction_Select) {
        char buffer[4];
        menu.GetItem(param2, buffer, sizeof(buffer));
        int line = StringToInt(buffer);
        int group = line/8;
        line = line%8;

        if (GetClientTeam(param1) > 1) {
            FakeClientCommand(param1, "voicemenu %d %d", group, line);
        } else {
            PlayVoiceCmdLine(param1, clientOldClass[param1], group, line);
        }
        
        clientVoiceMenu[param1] = 0;
    } else if (action==MenuAction_Cancel) {
        clientVoiceMenu[param1] = 0;
    } else if (action==MenuAction_End) {
        //menus stay alive
    }
    return 0;
}

// re enable features in spectate: +use

bool TR_Filter_NotSelfOrGhost(int entity, int contentsMask, any data) {
    return entity != data && entity != clientGhostRef[data];
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2]) {
    if (!cvarAllowPlayerUse.BoolValue || !CheckCommandAccess(client, "specghost_usebuttons", ADMFLAG_GENERIC)) return; //no permission to +use
    if (!!(buttons & IN_USE) && !(clientPrevButtons[client] & IN_USE) && CheckEntRef(clientGhostRef[client])) {
        float pos[3], vec[3], fwd[3];
        GetClientEyePosition(client, pos);
        GetClientEyeAngles(client, vec);
        GetAngleVectors(vec, fwd, NULL_VECTOR, NULL_VECTOR);
        ScaleVector(fwd, 64.0);
        AddVectors(pos, fwd, vec);

        Handle ray = TR_TraceRayFilterEx(pos, vec, MASK_PLAYERSOLID, RayType_EndPoint, TR_Filter_NotSelfOrGhost, client);
        if (TR_DidHit(ray)) {
            int potential_button = TR_GetEntityIndex(ray);
            if (potential_button > MaxClients) {
                AcceptEntityInput(potential_button, "Use", client, client);
            }
        }
        delete ray;
    }
    clientPrevButtons[client] = buttons;
}


bool CheckEntRef(int ref) {
    int idx = EntRefToEntIndex(ref);
    return idx != -1 && IsValidEdict(idx);
}