#if defined _tf2_weapons_included
  #endinput
#endif
#define _tf2_weapons_included

//Defines
#define MAX_WEAPON_NAME_LENGTH 32
#define MAX_DESCRIPTION_LENGTH 64
#define MAX_ATTRIBUTE_NAME_LENGTH 64
#define MAX_ATTRIBUTE_DISPLAY_LENGTH 64

//Typedefs
typedef RegisterAttribute_OnAction = function void (int client, int weapon, const char[] attrib, const char[] action, StringMap attributedata);

//Natives
native bool TF2Weapons_AllowAttributeRegisters();
native bool TF2Weapons_RegisterAttribute(const char[] attrib, RegisterAttribute_OnAction onaction);
native int TF2Weapons_GiveWeapon(int client, const char[] name, bool message = false);
native void TF2Weapons_RefillMag(int weapon);
native void TF2Weapons_RefillAmmo(int client, int weapon);

native int TF2Weapons_GetWeaponKeyInt(const char[] weapon, const char[] key);
native float TF2Weapons_GetWeaponKeyFloat(const char[] weapon, const char[] key);
native bool TF2Weapons_GetWeaponKeyString(const char[] weapon, const char[] key, char[] buffer, int size);

//Forwards
forward Action TF2Weapons_OnRegisterAttributes();
forward void TF2Weapons_OnRegisterAttributesPost();
forward Action TF2Weapons_OnRegisterWeaponConfig(const char[] name, const char[] file, KeyValues settings);
forward Action TF2Weapons_OnRegisterWeaponSetting(const char[] name, const char[] key, any value);
forward Action TF2Weapons_OnRegisterWeaponSettingStr(const char[] name, const char[] key, const char[] value);
forward void TF2Weapons_OnRegisterWeaponConfigPost(const char[] name, const char[] file, KeyValues settings);

#if !defined REQUIRE_PLUGIN
public void __pl_tf2_weapons_SetNTVOptional()
{
	MarkNativeAsOptional("TF2Weapons_AllowAttributeRegisters");
	MarkNativeAsOptional("TF2Weapons_RegisterAttribute");
	MarkNativeAsOptional("TF2Weapons_GiveWeapon");
}
#endif

public SharedPlugin __pl_tf2_weapons =
{
	name = "tf2-weapons",
	file = "tf2-weapons.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};
