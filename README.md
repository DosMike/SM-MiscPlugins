# About
This repo is for smaller plugins that I don't feel like creating a dedicated repo for.

Table Of Content
* [[TF2] Additional Settings](#TF2-Additional-Settings)
* [[TF2/MvM] AutoReady](#TF2MvM-AutoReady)
* [[ANY] Map Props](#ANY-Map-Props)
* [[TF2] QuickTrack](#TF2-QuickTrack)
* [[ANY] SlapAndBury](#ANY-SlapAndBury)
* [[ANY] SmartEdictOverflow](#ANY-SmartEdictOverflow)
* [[TF2] TDM Tickets](#TF2-TDM-Tickets)
* [[TF2] Train-Streak](#TF2-Train-Streak)
* [[ANY] TP Ask](#ANY-TP-Ask)

## [TF2] Additional Settings

Implement additional convars for whatever.

Currently adds the following:
* tf_backstabs 1 - Set to 0 to disable backstab crits
* mp_instagib 0 - Set to 1 to enable 1-hit kills for everything
* tf_medic_health_regen 1.0 - Can be used to scale the medics base health regen rate. If below 0.5 the blutsauger will start to drain health.

This plugin requires [TF2 RegenThink Hook](https://github.com/DosMike/TF2-RegenThinkHook), [TF2 attributes](https://github.com/FlaminSarge/tf2attributes) and [TF2 Utils](https://github.com/nosoop/SM-TFUtils/)

## [TF2/MvM] AutoReady
Basically a re-write of [avi9526's AutoReady](https://forums.alliedmods.net/showthread.php?t=223141).
If there are a hand full of players in your MvM server and one player is afk or something this plugin can auto ready them.
Problem with the original plugins was the quite annoying chat spam, that will hopefully be gone with this revision.

ConVars are the same to allow for drop in replacement:    
`mvm_autoready_threshold` - the amount of players that have to ready to force start the round    
`mvm_autoready_percent` - the ratio of players (0.0 .. 1.0) that have to ready to force start the round    
Admin Command:    
`sm_forceallready` - force all players into the ready state, starting the round. Requires the cheat admin flag.

## [ANY] Map Props
Allows server mods to spawn and manipulate and save props using an array of commands.

In order for props to save, add this block to your databases.cfg
```
	"MapProps"
	{
		"driver" "sqlite"
		"database" "mapprops"
	}
```

Commands are as follows (These have the permission ADMFLAG_GENERIC):
* sm_spawnprop &lt;model> - spawns a static model
* sm_spawnphys &lt;model> - spawns a physics model
* sm_deleteprop [ref] - deletes the ref or aimed prop
* sm_freezeprop [ref] - freezes the ref or aimed physics prop
* sm_unfreezeprop [ref] - unfreezes the ref or aimed physics prop
* sm_saveprop [ref] - add or update prop in database
* sm_removeprop [ref] - remove prop from database
* sm_propowner [ref] - shows who spawned the ref or aimed prop, if spawned with sm_spawn*
* sm_propmodel [ref] - returns the model path for the ref or aimed prop
* sm_colorprop &lt;r> &lt;g> &lt;b> [a] - colors a prop. r, g, b go from 0 to 255, a is optional with a min of 50
* sm_skinprop &lt;skin> - skin number from 0 to an arbitrary value, usually no higher than 15

## [TF2] QuickTrack
Allows servermods to quickly set up race tracks around maps with checkpoints, similar to bhop/surf timers.
The setup is done entirely through VGUI menus and player positioning.
Checkpoints within a track have to be visited in sequence for the attempt to progress, best times get a shoutout.

Saving tracks will write all open tracks with zones into a config file in tf/cfg/tracks/ named after the map.
The file is reloaded at map start, but can manually be reloaded at any point.

Commands:
* sm_edittrack [track] - Open the track editor for the track (ADMFLAG_GENERIC)
* sm_tracktop [track] - Open the top-scores for the current track, or the specified track
* sm_stoptrack - End the track a player is currently on

## [ANY] SlapAndBury
Three command for admins with the SLAY flag:
* sm_bury <target> / sm_unbury <target> - force players stuck into the ground.
* sm_rslap <target> [repeats] [delay] [damage] - use this instead of spamming your sm_slap bind or mashing up,enter in console

## [ANY] SmartEdictOverflow
A plugin that tries to keep your server alive just a little bit longer before it has to reset the map (or whatever you low edict action is).
Amout the limit: SEOP tries to be smart and counts edicts at the start of the map for a dynamic limit. If you specify a limit smaller than
the dynamic limit, it will pick the dynamic limit over your value to ensure gameplay is possible. If you still run into the edict limit at
that point, you probably got other problems. For this reason SEOP also does not really support reloading (the initial edict count will be off).

ConVars:
* `seop_edictlimit 2000` - When to start acting
* `seop_edictaction 2` - What to do over the limit: 0 = block spawning new stuff, 1 = try to delete old stuff, 2 = both
* `seop_edictlimitwarn 1950` - Start warning people when more that this amount of edicts is around (+overlay)
* `seop_edictlimitwarn_hudflags *` - Admin flag required to see get the overlay showed automatically (over warn limit)
* `seop_edictsperplayer 11` - How many edicts to guesstimate for every player in the dynamic limit

Commands:
* `seop_info` - Dump some stats into the console
* `seop_track` - Manually toggle the info overlay


## [TF2] TDM Tickets
A small plugin for TF2 servers that implements a battlefield like ticket system for team deathmatch.
It abuses mp_tournament mode to display tickets as team names *without* actually displaying any team ready popups during WFP.
Expect things to break if you have any other plugins that use tournament mode in any way.
For those that are not familiar: Spawning with this plugin requires a ticket, and once your team runs out of tickets, you loose the round.

There is really only one ConVar:
`sm_tdm_tickets` - set the amount of tickets each team has.

## [ANY] TP Ask
Bring a teleport request system similar to Minecrafts `/tpa`-Commands to the Source Engine.
As this plugins was designed as a VIP-Feature, it's commands require ADMFLAG_GENERIC by default, the command group is "tpask".

Players can request to teleport to other players, or ask other players to teleport to them using `/tpa` (or `/tpask`) and `/tpahere` (or `/tpaskhere`) respectively.
If no player is specified as command argument, a pick-player menu will open.

Asking a player will prompt them to `/tpaccept` or `/tpdeny` the request. If they are not interested they can also `/tptoggle` receiving any teleport requests.

After a teleport was accepted there's a warmup of `sm_tpa_warmup` seconds for the teleporting player. If they move of get hurt during this warmup, the teleport is interruped.
Otherwise the teleport takes place and the player is on a cooldown of `sm_tpa_cooldown` seconds before being able to teleport again. The config is written to `cfg/sourcemod/plugin.tpask.cfg`.

## [TF2] Train-Streak
Might already exist, couldn't find it, rewrote it. Gives environmental vehicles (usually trains in TF2) kills a killstreak.
