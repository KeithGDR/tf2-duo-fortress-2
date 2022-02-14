#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <misc-sm>
#include <misc-tf>
#include <misc-colors>
#include <sdktools>
#include <tf2_stocks>
#include <sdkhooks>
#include <tf2attributes>
#include <tf2items>
#include <tf2-weapons>
#include <tf_econ_data>

#define PLUGIN_TAG "{blue}[{ancient}Duo{blue}]{default}"
#define MAX_GROUPS 32

ConVar convar_SwitchTime;
ConVar convar_MaxPoints;

enum TF2GameType
{
	TF2GameType_Generic, 
	TF2GameType_CTF = 1, 
	TF2GameType_CP = 2, 
	TF2GameType_PL = 3, 
	TF2GameType_Arena = 4, 
}

TF2GameType g_MapType = TF2GameType_Generic;

//Groups
int iDuo_Points[MAX_GROUPS];
int iDuo_Requester[MAX_GROUPS];
int iDuo_Requested[MAX_GROUPS];
Menu hDuo_Menu_Spectator[MAX_GROUPS];
Handle hDuo_Hud_Alive[MAX_GROUPS];
int iDuo_Spectating[MAX_GROUPS];
bool bDuo_IsInUse[MAX_GROUPS];
int iDuo_SwitchTime[MAX_GROUPS];
Handle hDuo_SwitchTimer[MAX_GROUPS];
int iDuo_SpawnCache[MAX_GROUPS][2];
ArrayList hCooldownArray[MAX_GROUPS];

Menu hStart;
bool bAllowJointeam[MAXPLAYERS + 1];
bool bRemainFiring[MAXPLAYERS + 1];
bool bRemainZoomed[MAXPLAYERS + 1];
ArrayStack hQueueStack;

ArrayList h_aDisplayNames;
StringMap h_tCost;
StringMap h_tType;
StringMap h_tIndex;
StringMap h_tName;
StringMap h_tValue;
StringMap h_tDuration;
StringMap h_tApply;

//Handle g_hSDKAddObject;
Handle g_hSDKRemoveObject;
Handle g_hSDKSniperZoom;

//Custom Index Globals
float fRapidFire[MAXPLAYERS + 1];
int OffAW = -1;
float LastCharge[MAXPLAYERS + 1];
bool InAttack[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "Duo Fortress 2", 
	author = "Drixevel", 
	description = "Allows clients to duo in matches to grant powerups and other buffs.", 
	version = "1.0.0", 
	url = "https://drixevel.dev/"
};

public void OnPluginStart()
{
	//CSetPrefix("Duo");
	convar_SwitchTime = CreateConVar("sm_duo_switchtime", "120");
	convar_SwitchTime.AddChangeHook(OnConVarChange);
	
	convar_MaxPoints = CreateConVar("sm_duo_maxpoints", "200");
	convar_MaxPoints.AddChangeHook(OnConVarChange);
	
	RegConsoleCmd("sm_start", OpenStartMenu);
	RegConsoleCmd("sm_details", OpenDetailsPanel);
	RegConsoleCmd("sm_duo", OpenDuoMenu);
	RegConsoleCmd("sm_split", SplitDuoGroup);
	RegConsoleCmd("sm_queue", QueueForGroup);
	
	RegAdminCmd("sm_sp", SetPoints, ADMFLAG_ROOT);
	RegAdminCmd("sm_reloadconfig", ReloadConfig, ADMFLAG_ROOT);
	
	HookEvent("player_spawn", OnPlayerSpawn);
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("teamplay_point_captured", OnCapturePoint);
	HookEvent("teamplay_round_start", OnRoundStart);
	
	AddCommandListener(OnJoinTeam, "jointeam");
	
	CreateTimer(8.0, GrantDuoTeamsPoint, _, TIMER_REPEAT);
	CreateTimer(5.0, PairQueuePlayers, _, TIMER_REPEAT);
	
	h_aDisplayNames = new ArrayList(ByteCountToCells(MAX_NAME_LENGTH));
	h_tCost = new StringMap();
	h_tType = new StringMap();
	h_tIndex = new StringMap();
	h_tName = new StringMap();
	h_tValue = new StringMap();
	h_tDuration = new StringMap();
	h_tApply = new StringMap();
	
	hQueueStack = new ArrayStack();
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
			OnClientConnected(i);
		
		if (IsClientInGame(i))
		{
			OnClientPutInServer(i);
			
			if (TF2_GetClientTeam(i) != TFTeam_Spectator)
				TF2_ChangeClientTeam(i, TFTeam_Spectator);
		}
	}
	
	Handle hConfig = LoadGameConfigFile("duo_fortress_2.gamedata");
	
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Signature, "CTFPlayer::RemoveObject");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer); //CBaseObject
	if ((g_hSDKRemoveObject = EndPrepSDKCall()) == null)
		SetFailState("Failed To create SDKCall for CTFPlayer::RemoveObject signature");
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Virtual, "CTFSniperRifle::ZoomIn");
	if ((g_hSDKSniperZoom = EndPrepSDKCall()) == null)
		SetFailState("Failed To create SDKCall for CTFSniperRifle::ZoomIn signature");
	
	delete hConfig;
	
	OffAW = FindSendPropInfo("CBasePlayer", "m_hActiveWeapon");
}

public void OnConfigsExecuted()
{
	hStart = GenerateStartMenu();
	ReloadPerksConfig();
	
	g_MapType = TF2_GetGameType();
}

public void OnConVarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (convar == convar_SwitchTime)
	{
		int timer = StringToInt(newValue);
		
		for (int i = 0; i < MAX_GROUPS; i++)
			if (bDuo_IsInUse[i] && iDuo_SwitchTime[i] > timer)
				iDuo_SwitchTime[i] = timer;
	}
	else if (convar == convar_MaxPoints)
	{
		int points = StringToInt(newValue);
		
		for (int i = 0; i < MAX_GROUPS; i++)
			if (bDuo_IsInUse[i] && iDuo_Points[i] > points)
				iDuo_Points[i] = points;
	}
}

public void OnMapStart()
{
	PrecacheSound("items/powerup_pickup_agility.wav", true);
	PrecacheSound("items/powerup_pickup_vampire.wav", true);
}

public void OnPluginEnd()
{
	for (int i = 0; i < MAX_GROUPS; i++)
	{
		if (hDuo_Hud_Alive[i] != null)
		{
			int alive = iDuo_Spectating[i] != iDuo_Requester[i] ? iDuo_Requester[i] : iDuo_Requested[i];
			ClearSyncHud(alive, hDuo_Hud_Alive[i]);
		}
	}
}

public Action GrantDuoTeamsPoint(Handle timer)
{
	for (int i = 0; i < MAX_GROUPS; i++)
	{
		if (bDuo_IsInUse[i])
		{
			AddDuoPoints(i, 1);
			RedisplayPartnerMenu(i);
		}
	}
}

public void OnPlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	int available = GetDuoID(client);
	
	if (available != -1)
		RequestFrame(RequestFrame_SpawnLogic, available);
}

public void RequestFrame_SpawnLogic(any data)
{
	int available = data;
	
	int alive = iDuo_SpawnCache[available][0];
	int spectator = iDuo_SpawnCache[available][1];
	
	if (alive == 0 || spectator == 0)
		return;
		
	TFClassType class = TF2_GetPlayerClass(alive);
	
	int health = -1; int slot;
	if (IsPlayerAlive(alive))
	{
		float fOrig[3];
		GetClientAbsOrigin(alive, fOrig);
		
		float fAng[3];
		GetClientAbsAngles(alive, fAng);
		
		float fVel[3];
		GetEntPropVector(alive, Prop_Data, "m_vecVelocity", fVel);
		
		TeleportEntity(spectator, fOrig, fAng, fVel);
		
		health = GetClientHealth(alive);
		slot = GetPlayerActiveSlot(alive);
	}
	
	//Spy
	bool bDisguiseCheck; int disguise_class; int disguise_team; int disguise_targetindex; int disguise_health; int disguise_weapon; bool bCloaked; float cloak_amount;
	
	//Medic
	float fCharge;
	
	//Heavy
	bool bIsSlowed;
	
	//Sniper
	bool bIsZoomed;
	
	//Demoman
	int iDecaps;
	
	//Engineer
	int iMetal;
	
	switch (class)
	{
		case TFClass_Spy:
		{
			bDisguiseCheck = TF2_IsPlayerInCondition(alive, TFCond_Disguised);
			disguise_class = GetEntProp(alive, Prop_Send, "m_nDisguiseClass");
			disguise_team = GetEntProp(alive, Prop_Send, "m_nDisguiseTeam");
			disguise_targetindex = GetEntProp(alive, Prop_Send, "m_iDisguiseTargetIndex");
			disguise_health = GetEntProp(alive, Prop_Send, "m_iDisguiseHealth");
			disguise_weapon = GetEntProp(alive, Prop_Send, "m_hDisguiseWeapon");
			
			bCloaked = TF2_IsPlayerInCondition(alive, TFCond_Cloaked);
			cloak_amount = GetEntPropFloat(alive, Prop_Send, "m_flCloakMeter");
		}
		
		case TFClass_Medic:
		{
			int index = GetPlayerWeaponSlot(alive, 1);
			fCharge = GetEntPropFloat(index, Prop_Send, "m_flChargeLevel");
		}
		
		case TFClass_Heavy:
		{
			bIsSlowed = TF2_IsPlayerInCondition(alive, TFCond_Slowed);
		}
		
		case TFClass_Sniper:
		{
			bIsZoomed = TF2_IsPlayerInCondition(alive, TFCond_Zoomed);
		}
		
		case TFClass_DemoMan:
		{
			iDecaps = GetEntProp(alive, Prop_Send, "m_iDecapitations");
		}
		
		case TFClass_Engineer:
		{
			iMetal = GetEntProp(alive, Prop_Data, "m_iAmmo", 4, 3);
		}
	}
	
	TF2_SetPlayerClass(spectator, class);
	TF2_RegeneratePlayer(spectator);
	if (health != -1)SetEntityHealth(spectator, health);
	TF2_SwitchtoSlot(spectator, slot);
	
	switch (class)
	{
		case TFClass_Spy:
		{
			if (bDisguiseCheck)
			{
				TF2_AddCondition(spectator, TFCond_Disguised, TFCondDuration_Infinite, spectator);
				SetEntProp(spectator, Prop_Send, "m_nDisguiseClass", disguise_class);
				SetEntProp(spectator, Prop_Send, "m_nDisguiseTeam", disguise_team);
				SetEntProp(spectator, Prop_Send, "m_iDisguiseTargetIndex", disguise_targetindex);
				SetEntProp(spectator, Prop_Send, "m_iDisguiseHealth", disguise_health);
				SetEntProp(spectator, Prop_Send, "m_hDisguiseWeapon", disguise_weapon);
			}
			
			if (bCloaked)
			{
				TF2_AddCondition(spectator, TFCond_Cloaked, TFCondDuration_Infinite, spectator);
				SetEntPropFloat(spectator, Prop_Send, "m_flCloakMeter", cloak_amount);
			}
		}
		
		case TFClass_Medic:
		{
			int index = GetPlayerWeaponSlot(spectator, 1);
			SetEntPropFloat(index, Prop_Send, "m_flChargeLevel", fCharge);
		}
		
		case TFClass_Sniper:
		{
			if (bIsZoomed)
			{
				TF2_AddCondition(spectator, TFCond_Zoomed, TFCondDuration_Infinite, spectator);
				bRemainZoomed[spectator] = true;
				SDKCall(g_hSDKSniperZoom, GetPlayerWeaponSlot(spectator, 0));
			}
		}
		
		case TFClass_DemoMan:
		{
			SetEntProp(spectator, Prop_Send, "m_iDecapitations", iDecaps);
		}
		
		case TFClass_Engineer:
		{
			SetEntProp(spectator, Prop_Data, "m_iAmmo", iMetal, 4, 3);
		}
	}
	
	if (IsPlayerAlive(alive))
	{
		int weapon = -1;
		for (int i = 0; i <= 5; i++)
		{
			if ((weapon = GetPlayerWeaponSlot(alive, i)) == -1)
				continue;
			
			int index = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
			
			char classname[64];
			TF2Econ_GetItemClassName(index, classname, sizeof(classname));
			
			int new_weapon = TF2_GiveItem(spectator, classname, index);
			
			int m_iPrimaryAmmoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
			int m_iSecondaryAmmoType = GetEntProp(weapon, Prop_Send, "m_iSecondaryAmmoType");
			
			if (m_iPrimaryAmmoType != -1)
			{
				int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
				SetEntProp(new_weapon, Prop_Send, "m_iClip1", clip);
				
				int ammo = GetEntProp(alive, Prop_Send, "m_iAmmo", _, m_iPrimaryAmmoType);
				SetEntProp(spectator, Prop_Send, "m_iAmmo", ammo, _, m_iPrimaryAmmoType);
			}
			
			if (m_iSecondaryAmmoType != -1)
			{
				int clip = GetEntProp(weapon, Prop_Send, "m_iClip2");
				SetEntProp(new_weapon, Prop_Send, "m_iClip2", clip);
				
				int ammo = GetEntProp(alive, Prop_Send, "m_iAmmo", _, m_iSecondaryAmmoType);
				SetEntProp(spectator, Prop_Send, "m_iAmmo", ammo, _, m_iSecondaryAmmoType);
			}

			if (HasEntProp(weapon, Prop_Send, "m_iWeaponState"))
				SetEntProp(new_weapon, Prop_Send, "m_iWeaponState", GetEntProp(weapon, Prop_Send, "m_iWeaponState"));
			
			char sWeaponCurrent[64];
			GetEntityClassname(new_weapon, sWeaponCurrent, sizeof(sWeaponCurrent));
			
			if (StrEqual(sWeaponCurrent, "tf_weapon_minigun") && GetClientButtons(alive) & IN_ATTACK)
			{
				bRemainFiring[spectator] = true;
				CreateTimer(1.0, Timer_DisableAutoFire, spectator);
			}
		}

		if (bIsSlowed)
			TF2_AddCondition(spectator, TFCond_Slowed, TFCondDuration_Infinite, spectator);
	}
	
	if (hDuo_Hud_Alive[available] != null)
	{
		ClearSyncHud(alive, hDuo_Hud_Alive[available]);
	}
	
	DataPack pack = new DataPack();
	pack.WriteCell(alive);
	pack.WriteCell(spectator);
	pack.WriteCell(class);
	
	RequestFrame(RequestFrame_DelaySpecMove, pack);
	
	EmitSoundToClient(spectator, "items/powerup_pickup_vampire.wav");
	EmitSoundToClient(alive, "items/powerup_pickup_vampire.wav");
	
	iDuo_SpawnCache[available][0] = 0;
	iDuo_SpawnCache[available][1] = 0;
}

public Action Timer_DisableAutoFire(Handle timer, any data)
{
	bRemainFiring[data] = false;
}

public void RequestFrame_DelaySpecMove(DataPack pack)
{
	pack.Reset();
	
	int alive = pack.ReadCell();
	int spectator = pack.ReadCell();
	TFClassType class = pack.ReadCell();
	
	delete pack;
	
	if (class == TFClass_Engineer)
	{
		int obj = -1;
		while ((obj = FindEntityByClassname(obj, "obj_*")) != -1)
			if (GetEntPropEnt(obj, Prop_Send, "m_hBuilder") == alive)
				SetBuilder(obj, spectator);
	}
	
	bAllowJointeam[alive] = true;
	TF2_ChangeClientTeam(alive, TFTeam_Spectator);
	SetEntPropEnt(alive, Prop_Send, "m_hObserverTarget", spectator);
	bAllowJointeam[alive] = false;
}

int GetPlayerActiveSlot(int client)
{
	for (int i = 0; i <= 5; i++)
		if (GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon") == GetPlayerWeaponSlot(client, i))
			return i;
		
	return -1;
}

public void OnPlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int assister = GetClientOfUserId(GetEventInt(event, "assister"));
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return;
	}
	
	int available = GetDuoID(attacker);
	bool bRedisplay = false;
	if (attacker > 0 && IsClientInGame(attacker) && available != -1)
	{
		AddDuoPoints(available, 2);
		bRedisplay = true;
	}
	
	if (assister > 0 && IsClientInGame(assister) && available != -1)
	{
		AddDuoPoints(available, 1);
		bRedisplay = true;
	}
	
	if (bRedisplay)
	{
		RedisplayPartnerMenu(available);
	}
}

public void OnCapturePoint(Handle event, const char[] name, bool dontBroadcast)
{
	char sCappers[MAXPLAYERS + 1]; int iClient;
	GetEventString(event, "cappers", sCappers, MAXPLAYERS);
	for (int i = 0; i <= MAXPLAYERS; i++)
	{
		iClient = sCappers[i];
		if (iClient > 0 && iClient <= MaxClients && IsClientInGame(iClient))
		{
			int available = GetDuoID(iClient);
			
			if (available != -1)
			{
				AddDuoPoints(available, 5);
				RedisplayPartnerMenu(available);
			}
		}
	}
}

public void OnRoundStart(Handle event, const char[] name, bool dontBroadcast)
{
	if (g_MapType == TF2GameType_Arena)
	{
		for (int i = 0; i < MAX_GROUPS; i++)
		{
			if (bDuo_IsInUse[i])
			{
				SwitchDuo(i);
				iDuo_Points[i] = 0;
			}
		}
		
		CPrintToChatAll("%s {aliceblue}All groups have switched.", PLUGIN_TAG);
	}
}

public Action OnJoinTeam(int client, const char[] command, int argc)
{
	if (!IsInDuo(client))
	{
		CPrintToChat(client, "%s {aliceblue} You cannot join a team unless you're a part of a duo team.", PLUGIN_TAG);
		return Plugin_Handled;
	}

	if (!bAllowJointeam[client])
	{
		if (IsDuoSpec(client))
			CPrintToChat(client, "%s {aliceblue} You cannot join a team unless you're the active player.", PLUGIN_TAG);
				
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public Action OnSpawn(int client)
{
	if (!IsInDuo(client) || IsDuoSpec(client))
	{
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

bool IsDuoSpec(int client)
{
	for (int i = 0; i < MAX_GROUPS; i++)
	{
		if (bDuo_IsInUse[i] && iDuo_Spectating[i] == client)
		{
			return true;
		}
	}
	
	return false;
}

bool IsInDuo(int client)
{
	for (int i = 0; i < MAX_GROUPS; i++)
	{
		if (bDuo_IsInUse[i] && (iDuo_Requester[i] == client || iDuo_Requested[i] == client))
		{
			return true;
		}
	}
	
	return false;
}

int GetDuoID(int client)
{
	for (int i = 0; i < MAX_GROUPS; i++)
		if (bDuo_IsInUse[i] && (iDuo_Requester[i] == client || iDuo_Requested[i] == client))
			return i;
	
	return -1;
}

public void OnClientConnected(int client)
{
	bAllowJointeam[client] = false;
	bRemainFiring[client] = false;
	bRemainZoomed[client] = false;
	
	//Custom Index Globals
	fRapidFire[client] = 1.0;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_Spawn, OnSpawn);
	
	CreateTimer(5.0, DisplayConnectMessage, GetClientUserId(client));
}

public Action DisplayConnectMessage(Handle timer, any data)
{
	int client = GetClientOfUserId(data);
	
	if (client > 0 && IsClientInGame(client))
	{
		CPrintToChat(client, "%s {aliceblue}Welcome to duo fortress 2! To get started, type {ancient}!start {aliceblue}or {ancient}/start {aliceblue}in chat and read the gamemode details.", PLUGIN_TAG);
	}
}

public void OnClientDisconnect(int client)
{
	int available = GetDuoID(client);
	
	if (available != -1)
		NullDuoGroup(available, true);
}

public Action OpenStartMenu(int client, int args)
{
	hStart.Display(client, MENU_TIME_FOREVER);
	return Plugin_Handled;
}

public Action OpenDetailsPanel(int client, int args)
{
	DisplayDetailStart(client, 1);
	return Plugin_Handled;
}

public Action SplitDuoGroup(int client, int args)
{
	int available = GetDuoID(client);
	
	if (available != -1)
		NullDuoGroup(available);
	
	return Plugin_Handled;
}

public Action QueueForGroup(int client, int args)
{
	if (IsInDuo(client))
	{
		CPrintToChat(client, "%s {aliceblue}You cannot queue for a random duo group while in a duo group already.", PLUGIN_TAG);
		return Plugin_Handled;
	}
	
	hQueueStack.Push(GetClientUserId(client));
	CPrintToChat(client, "%s {aliceblue}You have been added to random queue.", PLUGIN_TAG);
	
	return Plugin_Handled;
}

public Action PairQueuePlayers(Handle timer)
{
	if (hQueueStack.Empty)
		return Plugin_Continue;
	
	int iRequester_id; int iRequested_id;
	if (hQueueStack.Pop(iRequester_id))
	{
		if (!hQueueStack.Pop(iRequested_id))
		{
			hQueueStack.Push(iRequester_id);
			return Plugin_Continue;
		}
		
		int iRequester = GetClientOfUserId(iRequester_id);
		int iRequested = GetClientOfUserId(iRequested_id);
		
		if (iRequester > 0 && iRequested > 0)
		{
			CPrintToChat(iRequester, "%s {aliceblue}You have been assigned a duo group with %N.", PLUGIN_TAG, iRequested);
			CPrintToChat(iRequested, "%s {aliceblue}You have been assigned a duo group with %N.", PLUGIN_TAG, iRequester);
			AssignDuoClients(iRequester, iRequested);
		}
		else
		{
			if (iRequester > 0)
				hQueueStack.Push(iRequester_id);
			
			if (iRequested > 0)
				hQueueStack.Push(iRequested_id);
		}
	}
	
	return Plugin_Continue;
}

void NullDuoGroup(int available, bool bDisconnected = false)
{
	int requester = iDuo_Requester[available];
	int requested = iDuo_Requested[available];
	
	iDuo_Points[available] = 0;
	iDuo_Requester[available] = 0;
	iDuo_Requested[available] = 0;
	
	delete hDuo_Menu_Spectator[available];
	delete hDuo_Hud_Alive[available];
	
	iDuo_Spectating[available] = 0;
	bDuo_IsInUse[available] = false;
	iDuo_SwitchTime[available] = 0;
	
	delete hDuo_SwitchTimer[available];
	delete hCooldownArray[available];
	
	if (bDisconnected)
	{
		if (requester > 0 && IsClientInGame(requester))
		{
			CPrintToChat(requester, "%s {aliceblue}Your opponent disconnected, cancelling the duo group.", PLUGIN_TAG);
			
			if (TF2_GetClientTeam(requester) != TFTeam_Spectator)
			{
				TF2_ChangeClientTeam(requester, TFTeam_Spectator);
			}
		}
		
		if (requested > 0 && IsClientInGame(requested))
		{
			CPrintToChat(requested, "%s {aliceblue}Your opponent disconnected, cancelling the duo group.", PLUGIN_TAG);
			
			if (TF2_GetClientTeam(requested) != TFTeam_Spectator)
			{
				TF2_ChangeClientTeam(requested, TFTeam_Spectator);
			}
		}
	}
	else
	{
		if (requester > 0 && IsClientInGame(requester))
		{
			CPrintToChat(requester, "%s {aliceblue}Your duo group has been split.", PLUGIN_TAG);
			
			if (TF2_GetClientTeam(requester) != TFTeam_Spectator)
			{
				TF2_ChangeClientTeam(requester, TFTeam_Spectator);
			}
		}
		
		if (requested > 0 && IsClientInGame(requested))
		{
			CPrintToChat(requested, "%s {aliceblue}Your duo group has been split.", PLUGIN_TAG);
			
			if (TF2_GetClientTeam(requested) != TFTeam_Spectator)
			{
				TF2_ChangeClientTeam(requested, TFTeam_Spectator);
			}
		}
	}
}

public Action OpenDuoMenu(int client, int args)
{
	if (!IsClientInGame(client))
		return Plugin_Handled;
	
	DisplayDuoMenu(client);
	return Plugin_Handled;
}

void DisplayDuoMenu(int client)
{
	Menu menu = new Menu(MenuHandle_OnSelectDuoPartner);
	menu.SetTitle("Pick a duo partner:");
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || client == i || IsInDuo(i))
			continue;
		
		char sName[MAX_NAME_LENGTH];
		GetClientName(i, sName, sizeof(sName));
		
		char sID[12];
		IntToString(GetClientUserId(i), sID, sizeof(sID));
		
		menu.AddItem(sID, sName);
	}
	
	if (menu.ItemCount < 1)
		menu.AddItem("", "[Not available]", ITEMDRAW_DISABLED);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandle_OnSelectDuoPartner(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sID[12]; char sName[MAX_NAME_LENGTH];
			GetMenuItem(menu, param2, sID, sizeof(sID), _, sName, sizeof(sName));
			int target = GetClientOfUserId(StringToInt(sID));
			
			if (target < 1 || IsInDuo(target))
			{
				CPrintToChat(param1, "%s {aliceblue}Client is no longer available, please choose a new client.", PLUGIN_TAG);
				DisplayDuoMenu(param1);
				return;
			}
			
			RequestTargetDuo(target, param1);
		}
		case MenuAction_End:
			delete menu;
	}
}

void RequestTargetDuo(int client, int requester)
{
	Menu menu = new Menu(MenuHandle_OnRequestDuo);
	menu.SetTitle("Duo request from '%N': ", requester);
	
	menu.AddItem("Yes", "Yes");
	menu.AddItem("No", "No");
	
	PushMenuInt(menu, "requester", GetClientUserId(requester));
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandle_OnRequestDuo(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sDecision[12];
			GetMenuItem(menu, param2, sDecision, sizeof(sDecision));
			
			int requester = GetClientOfUserId(GetMenuInt(menu, "requester"));
			
			if (StrEqual(sDecision, "Yes"))
			{
				if (requester < 1 || IsInDuo(requester))
				{
					CPrintToChat(param1, "%s {aliceblue}Requester client is no longer available.", PLUGIN_TAG);
					return;
				}
				
				ConfirmPosition(requester, param1);
			}
			else if (StrEqual(sDecision, "No"))
			{
				if (requester > 0 && !IsInDuo(requester))
				{
					CPrintToChat(requester, "%s {ancient}%N {aliceblue}has denied your duo request.", PLUGIN_TAG, param1);
					CPrintToChat(param1, "%s {aliceblue}You have denied {ancient}%N{aliceblue}'s duo request.", PLUGIN_TAG, requester);
				}
			}
		}
		case MenuAction_End:
			delete menu;
	}
}

void ConfirmPosition(int requester, int requested)
{
	Menu menu = new Menu(MenuHandle_ConfirmPosition);
	menu.SetTitle("Pick a position:");
	
	menu.AddItem("Player", "Player");
	menu.AddItem("Partner", "Partner");
	
	PushMenuInt(menu, "requested", requested);
	menu.Display(requester, MENU_TIME_FOREVER);
}

public int MenuHandle_ConfirmPosition(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sDecision[12];
			GetMenuItem(menu, param2, sDecision, sizeof(sDecision));
			
			int requested = GetMenuInt(menu, "requested");
			
			if (StrEqual(sDecision, "Player"))
			{
				AssignDuoClients(param1, requested);
			}
			else
			{
				AssignDuoClients(requested, param1);
			}
		}
		case MenuAction_End:
			delete menu;
	}
}

void AssignDuoClients(int requester, int requested)
{
	CPrintToChat(requester, "%s {aliceblue}Your new duo parter is now {ancient}%N{aliceblue}.", PLUGIN_TAG, requested);
	CPrintToChat(requested, "%s {aliceblue}Your new duo parter is now {ancient}%N{aliceblue}.", PLUGIN_TAG, requester);
	
	int available = GetLatestDuoSlot();
	iDuo_Points[available] = 0;
	iDuo_Requester[available] = requester;
	iDuo_Requested[available] = requested;
	RedisplayPartnerMenu(available);
	iDuo_Spectating[available] = requested;
	bDuo_IsInUse[available] = true;
	
	if (g_MapType != TF2GameType_Arena)
	{
		iDuo_SwitchTime[available] = GetConVarInt(convar_SwitchTime);
		hDuo_SwitchTimer[available] = CreateTimer(1.0, Timer_OnSwitchDuo, available, TIMER_REPEAT);
	}
	
	hCooldownArray[available] = new ArrayList(ByteCountToCells(256));
	
	TFTeam team = view_as<TFTeam>(GetRandomInt(2, 3));
	bAllowJointeam[requester] = true;
	TF2_ChangeClientTeam(requester, team);
	TF2_SetPlayerClass(requester, view_as<TFClassType>(GetRandomInt(1, 9)));
	CreateTimer(0.5, Timer_RespawnPlayer, requester);
	
	bAllowJointeam[requested] = true;
	TF2_ChangeClientTeam(requested, TFTeam_Spectator);
	bAllowJointeam[requested] = false;
	
	SetEntPropEnt(requested, Prop_Send, "m_hObserverTarget", requester);
}

public Action Timer_OnSwitchDuo(Handle timer, any data)
{
	int available = data;
	
	iDuo_SwitchTime[available]--;
	
	PrintHintText(iDuo_Requester[available], "Switch in... %i", iDuo_SwitchTime[available]);
	PrintHintText(iDuo_Requested[available], "Switch in... %i", iDuo_SwitchTime[available]);
	StopSound(iDuo_Requester[available], SNDCHAN_STATIC, "UI/hint.wav");
	StopSound(iDuo_Requested[available], SNDCHAN_STATIC, "UI/hint.wav");
	
	if (iDuo_SwitchTime[available] <= 0)
	{
		iDuo_SwitchTime[available] = GetConVarInt(convar_SwitchTime);
		SwitchDuo(available);
	}
}

int GetLatestDuoSlot()
{
	for (int i = 0; i < MAX_GROUPS; i++)
	{
		if (!bDuo_IsInUse[i])
		{
			return i;
		}
	}
	
	return -1;
}

int GetDuoAlivePlayer(int available)
{
	int requester = iDuo_Requester[available];
	int requested = iDuo_Requested[available];
	int spectating = iDuo_Spectating[available];
	
	if (spectating == requester)
	{
		return requested;
	}
	else
	{
		return requester;
	}
}

void RedisplayPartnerMenu(int available)
{
	delete hDuo_Menu_Spectator[available];
	hDuo_Menu_Spectator[available] = GeneratePartnerMenu(available);
	hDuo_Menu_Spectator[available].Display(iDuo_Spectating[available], MENU_TIME_FOREVER);
	
	RegenerateAliveHUDText(available);
}

Menu GeneratePartnerMenu(int available)
{
	Menu menu = new Menu(MenuHandle_PartnerMenu);
	menu.SetTitle("Partner Menu\nPoints: %i", iDuo_Points[available]);
	
	char sName[MAX_NAME_LENGTH]; int iCost; char sDisplay[MAX_NAME_LENGTH + 12];
	for (int i = 0; i < h_aDisplayNames.Length; i++)
	{
		h_aDisplayNames.GetString(i, sName, sizeof(sName));
		
		h_tCost.GetValue(sName, iCost);
		
		Format(sDisplay, sizeof(sDisplay), "[%i] %s", iCost, sName);
		
		menu.AddItem(sName, sDisplay);
	}
	
	PushMenuInt(menu, "available", available);
	return menu;
}

void RegenerateAliveHUDText(int available)
{
	int alive = iDuo_Spectating[available] != iDuo_Requester[available] ? iDuo_Requester[available] : iDuo_Requested[available];
	
	if (hDuo_Hud_Alive[available] != null)
	{
		ClearSyncHud(alive, hDuo_Hud_Alive[available]);
		delete hDuo_Hud_Alive[available];
	}
	
	hDuo_Hud_Alive[available] = CreateHudSynchronizer();
	SetHudTextParams(0.0, 0.3, 999999.0, 73, 205, 238, 255);
	ShowSyncHudText(alive, hDuo_Hud_Alive[available], "Points: %i\n", iDuo_Points[available]);
}

public int MenuHandle_PartnerMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sName[MAX_NAME_LENGTH + 12];
			GetMenuItem(menu, param2, sName, sizeof(sName));
			
			int available = GetMenuInt(menu, "available");
			
			if (iDuo_Spectating[available] != param1)
			{
				return;
			}
			
			int iCost;
			h_tCost.GetValue(sName, iCost);
			
			char sType[32];
			h_tType.GetString(sName, sType, sizeof(sType));
			
			int iIndex = -1;
			h_tIndex.GetValue(sName, iIndex);
			
			char sIndexName[256];
			h_tName.GetString(sName, sIndexName, sizeof(sIndexName));
			
			float fValue;
			h_tValue.GetValue(sName, fValue);
			
			float fDuration;
			h_tDuration.GetValue(sName, fDuration);
			
			char sApply[256];
			h_tApply.GetString(sName, sApply, sizeof(sApply));
			
			ActivateDuoPerk(available, param1, sName, iCost, sType, iIndex, sIndexName, fValue, fDuration, sApply);
			
			RedisplayPartnerMenu(available);
		}
	}
}

void ActivateDuoPerk(int available, int caster, const char[] name, int points, const char[] type, int index, char[] index_name, float value, float duration, const char[] apply)
{
	if (iDuo_Points[available] >= points)
	{
		iDuo_Points[available] -= points;
	}
	else
	{
		CPrintToChat(caster, "%s {aliceblue}Not enough points to activate this perk.", PLUGIN_TAG);
		return;
	}
	
	int alive = GetDuoAlivePlayer(available);
	
	if (alive != -1)
	{
		//PrintToServer(" %i \n %N \n %N \n %s \n %i \n %s \n %i \n %s \n %f \n %f \n %s", available, alive, caster, name, points, type, index, index_name, value, duration, apply);
		
		Handle hSync = CreateHudSynchronizer();
		SetHudTextParams(0.0, 0.4, 3.0, 73, 205, 238, 255);
		ShowSyncHudText(alive, hSync, "%s", name);
		delete hSync;
		
		EmitSoundToClient(alive, "items/powerup_pickup_agility.wav");
		EmitSoundToClient(caster, "items/powerup_pickup_agility.wav");
		
		if (StrEqual(type, "condition"))
		{
			if (index > 0)
			{
				TF2_AddCondition(alive, view_as<TFCond>(index), value, iDuo_Spectating[available]);
			}
			else
			{
				LogError("Error, index for condition perk '%s' is -1, skipping.", name);
				return;
			}
		}
		else if (StrEqual(type, "attribute"))
		{
			if (hCooldownArray[available].FindValue(index) != -1)
			{
				return;
			}
			
			if (StrEqual(apply, "client"))
			{
				if (strlen(index_name) > 0)
				{
					TF2Attrib_SetByName(alive, index_name, value);
				}
				else if (index > -1)
				{
					TF2Attrib_SetByDefIndex(alive, index, value);
				}
			}
			else if (StrEqual(apply, "weapons"))
			{
				for (int i = 0; i < 3; i++)
				{
					int weapon = GetPlayerWeaponSlot(alive, i);
					
					if (weapon != -1)
					{
						if (strlen(index_name) > 0)
						{
							TF2Attrib_SetByName(weapon, index_name, value);
						}
						else if (index > -1)
						{
							TF2Attrib_SetByDefIndex(weapon, index, value);
						}
						else
						{
							LogError("Error, no valid name or index fields available for perk '%s'.", name);
							return;
						}
					}
				}
			}
			else
			{
				LogError("Error, unknown apply string for perk '%s': %s", name, strlen(apply) > 0 ? apply : "N/A");
				return;
			}
			
			if (duration > 0.0)
			{
				int remove = -1;
				if (StrEqual(apply, "client"))
				{
					remove = hCooldownArray[available].Push(index);
				}
				else if (StrEqual(apply, "weapons"))
				{
					remove = hCooldownArray[available].PushString(index_name);
				}
				
				DataPack pack;
				CreateDataTimer(duration, Timer_OnRemoveAttribute, pack, TIMER_FLAG_NO_MAPCHANGE);
				pack.WriteCell(GetClientUserId(alive));
				pack.WriteCell(index);
				pack.WriteString(index_name);
				pack.WriteString(apply);
				pack.WriteCell(available);
				pack.WriteCell(remove);
			}
		}
		else if (StrEqual(type, "custom"))
		{
			GiveCustomPerk(alive, index, value, duration);
		}
	}
}

public Action Timer_OnRemoveAttribute(Handle timer, DataPack pack)
{
	pack.Reset();
	
	int client = GetClientOfUserId(pack.ReadCell());
	int index = pack.ReadCell();
	
	char sName[256];
	pack.ReadString(sName, sizeof(sName));
	
	char sApply[32];
	pack.ReadString(sApply, sizeof(sApply));
	
	int available = pack.ReadCell();
	int remove = pack.ReadCell();
	
	delete pack;
	
	if (StrEqual(sApply, "client"))
	{
		if (strlen(sName) > 0)
		{
			TF2Attrib_RemoveByName(client, sName);
		}
		else if (index > -1)
		{
			TF2Attrib_RemoveByDefIndex(client, index);
		}
	}
	else if (StrEqual(sApply, "weapons"))
	{
		for (int i = 0; i < 3; i++)
		{
			int weapon = GetPlayerWeaponSlot(client, i);
			
			if (weapon != -1)
			{
				if (strlen(sName) > 0)
				{
					TF2Attrib_RemoveByName(weapon, sName);
				}
				else if (index != 0)
				{
					TF2Attrib_RemoveByDefIndex(weapon, index);
				}
			}
		}
	}
	
	if (remove != -1)
	{
		hCooldownArray[available].Erase(remove);
	}
}

void TF2_SwitchtoSlot(int client, int slot)
{
	if (slot >= 0 && slot <= 5 && IsClientInGame(client) && IsPlayerAlive(client))
	{
		char sClassName[64];
		int wep = GetPlayerWeaponSlot(client, slot);
		if (wep > MaxClients && IsValidEdict(wep) && GetEdictClassname(wep, sClassName, sizeof(sClassName)))
		{
			FakeClientCommandEx(client, "use %s", sClassName);
			SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", wep);
			ChangeEdictState(wep, FindDataMapInfo(wep, "m_nViewModelIndex"));
		}
	}
}

void GiveCustomPerk(int client, int index, float value, float duration)
{
	switch (index)
	{
		case 1:
		{
			fRapidFire[client] = value;
			CreateTimer(duration, Timer_DisableRapidFire, client);
		}
	}
}

public Action Timer_DisableRapidFire(Handle timer, any data)
{
	fRapidFire[data] = 1.0;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (fRapidFire[client] != 1.0)
	{
		if (buttons & IN_ATTACK2)
		{
			int entity = GetEntDataEnt2(client, OffAW);
			if (entity != -1)
			{
				char weap[50];
				GetEdictClassname(entity, weap, sizeof(weap));
				
				if (strcmp(weap, "tf_weapon_particle_cannon") == 0)
				{
					float charge = GetEntPropFloat(entity, Prop_Send, "m_flChargeBeginTime");
					float chargemod = charge - 4.0;
					if (charge != 0 && LastCharge[client] != chargemod)
					{
						LastCharge[client] = chargemod;
						SetEntPropFloat(entity, Prop_Send, "m_flChargeBeginTime", chargemod);
					}
				}
			}
		}
		
		if (buttons & IN_ATTACK || buttons & IN_ATTACK2)
			InAttack[client] = true;
		else
			InAttack[client] = false;
	}
	
	if (bRemainFiring[client])
		buttons |= IN_ATTACK;
	
	if (bRemainZoomed[client])
	{
		buttons |= IN_ZOOM;
		bRemainZoomed[client] = false;
	}
	
	return Plugin_Continue;
}

public void OnGameFrame()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsPlayerAlive(i) && fRapidFire[i] != 1.0 && InAttack[i])
			ModRateOfFire(i, fRapidFire[i]);
}

void ModRateOfFire(int client, float Amount)
{
	int entity = GetEntDataEnt2(client, OffAW);
	
	if (entity != -1)
	{
		float m_flNextPrimaryAttack = GetEntPropFloat(entity, Prop_Send, "m_flNextPrimaryAttack");
		float m_flNextSecondaryAttack = GetEntPropFloat(entity, Prop_Send, "m_flNextSecondaryAttack");
		
		if (Amount > 12)
			SetEntPropFloat(entity, Prop_Send, "m_flPlaybackRate", 12.0);
		else
			SetEntPropFloat(entity, Prop_Send, "m_flPlaybackRate", Amount);
				
		float GameTime = GetGameTime();
		
		float PeTime = (m_flNextPrimaryAttack - GameTime) - ((Amount - 1.0) / 50);
		float SeTime = (m_flNextSecondaryAttack - GameTime) - ((Amount - 1.0) / 50);
		float FinalP = PeTime + GameTime;
		float FinalS = SeTime + GameTime;
		
		SetEntPropFloat(entity, Prop_Send, "m_flNextPrimaryAttack", FinalP);
		SetEntPropFloat(entity, Prop_Send, "m_flNextSecondaryAttack", FinalS);
	}
}

public Action SetPoints(int client, int args)
{
	char sArg[64];
	GetCmdArg(1, sArg, sizeof(sArg));
	
	char sArg2[64];
	GetCmdArg(2, sArg2, sizeof(sArg2));
	int points = StringToInt(sArg2);
	
	int target = FindTarget(client, sArg, true, false);
	int available = GetDuoID(target);
	
	if (available != -1)
	{
		AddDuoPoints(available, points);
		CPrintToChat(target, "%s {aliceblue}Your group has been given {ancient}%i {aliceblue}points.", PLUGIN_TAG, points);
	}
	
	return Plugin_Handled;
}

void AddDuoPoints(int available, int points)
{
	iDuo_Points[available] += points;
	int max = GetConVarInt(convar_MaxPoints);
	
	if (iDuo_Points[available] > max)
		iDuo_Points[available] = max;
}

void SwitchDuo(int available)
{
	int spectator = iDuo_Spectating[available];
	int alive = spectator != iDuo_Requester[available] ? iDuo_Requester[available] : iDuo_Requested[available];
	
	iDuo_SpawnCache[available][0] = alive;
	iDuo_SpawnCache[available][1] = spectator;
	
	TFClassType class = TF2_GetPlayerClass(alive);
	TFTeam team = TF2_GetClientTeam(alive);

	bAllowJointeam[spectator] = true;

	TF2_ChangeClientTeam(spectator, team);
	TF2_SetPlayerClass(spectator, class);
	bAllowJointeam[spectator] = false;
	
	iDuo_Spectating[available] = alive;
}

public Action Timer_RespawnPlayer(Handle timer, any data)
{
	TF2_RespawnPlayer(data);
	bAllowJointeam[data] = true;
}

Menu GenerateStartMenu()
{
	Menu menu = new Menu(MenuHandle_StartMenu);
	menu.SetTitle("Duo Fortress 2");
	
	menu.AddItem("!details", "Details");
	menu.AddItem("!duo", "Start a Duo");
	menu.AddItem("!queue", "Queue for a Duo");
	menu.AddItem("!split", "Split a Duo");
	
	return menu;
}

public int MenuHandle_StartMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sCommand[64];
			GetMenuItem(menu, param2, sCommand, sizeof(sCommand));
			
			FakeClientCommand(param1, "say %s", sCommand);
		}
	}
}

public Action ReloadConfig(int client, int args)
{
	ReloadPerksConfig();
	CPrintToChat(client, "%s {aliceblue}Attributes config has reloaded.", PLUGIN_TAG);
	return Plugin_Handled;
}

void ReloadPerksConfig()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "configs/duo_perks.cfg");
	
	KeyValues kv = new KeyValues("duo_perks");
	
	if (!kv.ImportFromFile(sPath) || !kv.GotoFirstSubKey())
		return;
	
	h_aDisplayNames.Clear();
	h_tCost.Clear();
	h_tType.Clear();
	h_tIndex.Clear();
	h_tName.Clear();
	h_tValue.Clear();
	h_tDuration.Clear();
	h_tApply.Clear();

	char sDisplayName[MAX_NAME_LENGTH]; int iCost; char sType[32]; int iIndex; char sIndexName[256]; float fValue; float fDuration; char sApply[32];
	do {
		kv.GetSectionName(sDisplayName, sizeof(sDisplayName));
		
		iCost = kv.GetNum("cost");
		kv.GetString("type", sType, sizeof(sType));
		iIndex = kv.GetNum("index");
		kv.GetString("name", sIndexName, sizeof(sIndexName));
		fValue = kv.GetFloat("value");
		fDuration = kv.GetFloat("duration");
		kv.GetString("apply", sApply, sizeof(sApply));
		
		h_aDisplayNames.PushString(sDisplayName);
		h_tCost.SetValue(sDisplayName, iCost);
		h_tType.SetString(sDisplayName, sType);
		h_tIndex.SetValue(sDisplayName, iIndex);
		h_tName.SetString(sDisplayName, sIndexName);
		h_tValue.SetValue(sDisplayName, fValue);
		h_tDuration.SetValue(sDisplayName, fDuration);
		h_tApply.SetString(sDisplayName, sApply);
		
	} while (kv.GotoNextKey());
	
	delete kv;
}

/*
public int TF2Items_OnGiveNamedItem_Post(int client, char[] classname, int index, int level, int quality, int entity)
{
	SetEntProp(entity, Prop_Send, "m_bValidatedAttachedEntity", 1);
}
*/

TF2GameType TF2_GetGameType()
{
	return view_as<TF2GameType>(GameRules_GetProp("m_nGameType"));
}

stock void SetBuilder(int obj, int client)
{
	int iBuilder = GetEntPropEnt(obj, Prop_Send, "m_hBuilder");
	bool bMiniBuilding = GetEntProp(obj, Prop_Send, "m_bMiniBuilding") || GetEntProp(obj, Prop_Send, "m_bDisposableBuilding");
	
	if (iBuilder > 0 && iBuilder <= MaxClients && IsClientInGame(iBuilder))
		SDKCall(g_hSDKRemoveObject, iBuilder, obj);
	
	SetEntPropEnt(obj, Prop_Send, "m_hBuilder", -1);
	AcceptEntityInput(obj, "SetBuilder", client);
	SetEntPropEnt(obj, Prop_Send, "m_hBuilder", client);
	
	SetVariantInt(GetClientTeam(client));
	AcceptEntityInput(obj, "SetTeam");
	
	SetEntProp(obj, Prop_Send, "m_nSkin", bMiniBuilding ? GetClientTeam(client) : GetClientTeam(client) - 2);
}

//EWW
void DisplayDetailStart(int client, int menu_item)
{
	Handle hPanel = CreatePanel();
	
	switch (menu_item)
	{
		case 1:
		{
			SetPanelTitle(hPanel, "Duo Fortress 2 - How to Play \n \n");
			
			DrawPanelText(hPanel, "This gamemode has two roles: \n \n");
			DrawPanelText(hPanel, " - Alive Partner");
			DrawPanelText(hPanel, "Their job is to play the game and coordinate with their spectator partner to win the game. \n \n");
			DrawPanelText(hPanel, " - Spectator Partner");
			DrawPanelText(hPanel, "Their job is to grant perks to the alive partner to win the game. \n \n");
			DrawPanelItem(hPanel, "Next Page");
			DrawPanelItem(hPanel, "Close All");
			
			SendPanelToClient(hPanel, client, PanelHandler_Display_1, MENU_TIME_FOREVER);
		}
		case 2:
		{
			SetPanelTitle(hPanel, "Duo Fortress 2 - Perks \n \n");
			
			DrawPanelText(hPanel, "Spectator partners grant available perks based off points to the aliver player. \n \n");
			DrawPanelText(hPanel, "Methods of getting points:");
			DrawPanelText(hPanel, " - Kills [2 point]\n - Assists [1 point]\n - Capturing Objectives [5 points] \n \n");
			DrawPanelText(hPanel, "Points are reset between rounds. \n \n");
			DrawPanelItem(hPanel, "Previous Page");
			DrawPanelItem(hPanel, "Next Page");
			DrawPanelItem(hPanel, "Close All");
			
			SendPanelToClient(hPanel, client, PanelHandler_Display_2, MENU_TIME_FOREVER);
		}
		case 3:
		{
			SetPanelTitle(hPanel, "Duo Fortress 2 - Switching \n \n");
			
			DrawPanelText(hPanel, "Switching takes the alive partner and places them in the spectator seat and vice versa for the spectator partner. \n \n");
			DrawPanelText(hPanel, "You keep the following between switches:\n - Position/Velocity\n - Weapons and ammo\n - Buildables (Engineer)\n - Disguise/Cloak (Spy)\n - Attributes and current perks. \n \n");
			DrawPanelText(hPanel, "Switching happens every 120 seconds in normal modes and between rounds in Arena. \n \n");
			DrawPanelItem(hPanel, "Previous Page");
			DrawPanelItem(hPanel, "Next Page");
			DrawPanelItem(hPanel, "Close All");
			
			SendPanelToClient(hPanel, client, PanelHandler_Display_3, MENU_TIME_FOREVER);
		}
		case 4:
		{
			SetPanelTitle(hPanel, "Duo Fortress 2 - How to start \n \n");
			
			DrawPanelText(hPanel, "Type '!duo' in chat and pick your designated partner or type '!queue' in chat to find a random partner. \n \n");
			
			DrawPanelItem(hPanel, "Previous Page");
			DrawPanelItem(hPanel, "Next Page", ITEMDRAW_DISABLED);
			DrawPanelItem(hPanel, "Close All");
			
			SendPanelToClient(hPanel, client, PanelHandler_Display_4, MENU_TIME_FOREVER);
		}
	}
	
	delete hPanel;
}

public int PanelHandler_Display_1(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			//PrintToChat(param1, "%i", param2);
			
			switch (param2)
			{
				case 1:
				{
					DisplayDetailStart(param1, 2);
				}
				case 2:
				{
					//Close
				}
			}
		}
	}
}

public int PanelHandler_Display_2(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			//PrintToChat(param1, "%i", param2);
			
			switch (param2)
			{
				case 1:
				{
					DisplayDetailStart(param1, 1);
				}
				case 2:
				{
					DisplayDetailStart(param1, 3);
				}
				case 3:
				{
					//Close
				}
			}
		}
	}
}

public int PanelHandler_Display_3(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			//PrintToChat(param1, "%i", param2);
			
			switch (param2)
			{
				case 1:
				{
					DisplayDetailStart(param1, 2);
				}
				case 2:
				{
					DisplayDetailStart(param1, 4);
				}
				case 3:
				{
					//Close	
				}
			}
		}
	}
}

public int PanelHandler_Display_4(Handle menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			//PrintToChat(param1, "%i", param2);
			
			switch (param2)
			{
				case 1:
				{
					DisplayDetailStart(param1, 3);
				}
				case 2:
				{
					DisplayDetailStart(param1, 5);
				}
				case 3:
				{
					//Close
				}
			}
		}
	}
}

/*
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Signature, "CTFPlayer::AddObject");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer); //CBaseObject
	if ((g_hSDKAddObject = EndPrepSDKCall()) == INVALID_HANDLE)
	{
		SetFailState("Failed To create SDKCall for CTFPlayer::AddObject signature");
	}
	
	RegAdminCmd("sm_disownbuildings", Command_Remove, ADMFLAG_ROOT);
	RegAdminCmd("sm_ownbuildings", Command_Add, ADMFLAG_ROOT);
	
public Action Command_Remove(int client, int args)
{
	if (TF2_GetPlayerClass(client) == TFClass_Engineer)
	{
		int obj = -1;
		while ((obj = FindEntityByClassname(obj, "obj_*")) != -1)
		{
			CPrintToChatAll("Disowning building (%i) of %N", obj, GetEntPropEnt(obj, Prop_Send, "m_hBuilder"));
			
			SetEntPropEnt(obj, Prop_Send, "m_hBuilder", -1);
			SDKCall(g_hSDKRemoveObject, client, obj);
		}
	}
	
	return Plugin_Handled;
}

public Action Command_Add(int client, int args)
{
	if (TF2_GetPlayerClass(client) == TFClass_Engineer)
	{
		int obj = -1;
		while ((obj = FindEntityByClassname(obj, "obj_*")) != -1)
		{
			CPrintToChatAll("Owning building (%i) to %N", obj, client);
			
			SetEntPropEnt(obj, Prop_Send, "m_hBuilder", client);
			SDKCall(g_hSDKAddObject, client, obj);
		}
	}
	
	return Plugin_Handled;
}
*/