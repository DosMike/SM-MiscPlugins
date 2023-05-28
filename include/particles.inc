/**
 * Everything you need to precache and play particles. Borrows from SMLib
 */
#if defined __REBANE_STOCK_PARTICLE_H__
#endinput
#endif
#define __REBANE_STOCK_PARTICLE_H__

#include <sourcemod>

enum ParticleAttachment_t { // particle_parse.h
	PATTACH_INVALID = -1,			// Not in original, indicates invalid initial value
	PATTACH_ABSORIGIN = 0,			// Create at absorigin, but don't follow
	PATTACH_ABSORIGIN_FOLLOW,		// Create at absorigin, and update to follow the entity
	PATTACH_CUSTOMORIGIN,			// Create at a custom origin, but don't follow
	PATTACH_POINT,					// Create on attachment point, but don't follow
	PATTACH_POINT_FOLLOW,			// Create on attachment point, and update to follow the entity
	PATTACH_WORLDORIGIN,			// Used for control points that don't attach to an entity
	PATTACH_ROOTBONE_FOLLOW,		// Create at the root bone of the entity, and update to follow
};

void TE_StartParticle(const char[] name, float pos[3], float offset[3], float angles[3], int parentTo=-1, ParticleAttachment_t attachType=PATTACH_INVALID, int attachPoint=0, bool reset=false) {
	static int table = INVALID_STRING_TABLE;
	if (table == INVALID_STRING_TABLE) {
		if ((table=FindStringTable("ParticleEffectNames"))==INVALID_STRING_TABLE)
			ThrowError("Could not find string table for particles");
	}
	char tmp[64];
	int count = GetStringTableNumStrings(table);
	int index = INVALID_STRING_INDEX;
	for (int i;i<count;i++) {
		ReadStringTable(table, i, tmp, sizeof(tmp));
		if (StrEqual(tmp, name)) {
			index = i; break;
		}
//		PrintToServer("Particle: %s", tmp);
	}
	if (index == INVALID_STRING_INDEX) {
		ThrowError("Could not find particle in string table");
	}
	TE_Start("TFParticleEffect");
	TE_WriteFloat("m_vecOrigin[0]", pos[0]);
	TE_WriteFloat("m_vecOrigin[1]", pos[1]);
	TE_WriteFloat("m_vecOrigin[2]", pos[2]);
	TE_WriteFloat("m_vecStart[0]", offset[0]);
	TE_WriteFloat("m_vecStart[1]", offset[1]);
	TE_WriteFloat("m_vecStart[2]", offset[2]);
	TE_WriteVector("m_vecAngles", angles);
	TE_WriteNum("m_iParticleSystemIndex", index);
	if (parentTo!=-1) TE_WriteNum("entindex", parentTo);
	if (attachType!=PATTACH_INVALID) TE_WriteNum("m_iAttachType", view_as<int>(attachType));
	if (attachPoint>0) TE_WriteNum("m_iAttachmentPointIndex", attachPoint);
	TE_WriteNum("m_bResetParticles", reset?1:0);
}

// ===== From SMLib, full credit to those guys =====

/*
 * Rewrite of FindStringIndex, because in my tests
 * FindStringIndex failed to work correctly.
 * Searches for the index of a given string in a string table.
 *
 * @param tableidx		A string table index.
 * @param str			String to find.
 * @return				String index if found, INVALID_STRING_INDEX otherwise.
 */
stock int FindStringIndex2(int tableidx, const char[] str)
{
	char buf[1024];

	int numStrings = GetStringTableNumStrings(tableidx);
	for (int i=0; i < numStrings; i++) {
		ReadStringTable(tableidx, i, buf, sizeof(buf));

		if (StrEqual(buf, str)) {
			return i;
		}
	}

	return INVALID_STRING_INDEX;
}

/*
 * Precaches the given particle system.
 * It's best to call this OnMapStart().
 * Code based on Rochellecrab's, thanks.
 *
 * @param particleSystem	Name of the particle system to precache.
 * @return					Returns the particle system index, INVALID_STRING_INDEX on error.
 */
stock int PrecacheParticleSystem(const char[] particleSystem)
{
	static int particleEffectNames = INVALID_STRING_TABLE;

	if (particleEffectNames == INVALID_STRING_TABLE) {
		if ((particleEffectNames = FindStringTable("ParticleEffectNames")) == INVALID_STRING_TABLE) {
			return INVALID_STRING_INDEX;
		}
	}

	int index = FindStringIndex2(particleEffectNames, particleSystem);
	if (index == INVALID_STRING_INDEX) {
		int numStrings = GetStringTableNumStrings(particleEffectNames);
		if (numStrings >= GetStringTableMaxStrings(particleEffectNames)) {
			return INVALID_STRING_INDEX;
		}

		AddToStringTable(particleEffectNames, particleSystem);
		index = numStrings;
	}

	return index;
}

/*
 * Checks if the particle system is precached.
 *
 * @param material			Name of the particle system
 * @return					True if it is precached, false otherwise.
 */
stock bool IsParticleSystemPrecached(const char[] particleSystem)
{
	static int particleEffectNames = INVALID_STRING_TABLE;

	if (particleEffectNames == INVALID_STRING_TABLE) {
		if ((particleEffectNames = FindStringTable("ParticleEffectNames")) == INVALID_STRING_TABLE) {
			return false;
		}
	}

	return (FindStringIndex2(particleEffectNames, particleSystem) != INVALID_STRING_INDEX);
}