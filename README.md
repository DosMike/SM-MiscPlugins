# About
This repo is for smaller plugins that I don't feel like creating a dedicated repo for

## SlapAndBury
Three command for admins with the SLAY flag:
* sm_bury <target> / sm_unbury <target> - force players stuck into the ground.
* sm_rslap <target> [repeats] [delay] [damage] - use this instead of spamming your sm_slap bind or mashing up,enter in console

## TF2 AutoReady
Basically a re-write of [avi9526's AutoReady](https://forums.alliedmods.net/showthread.php?t=223141).
If there are a hand full of players in your MvM server and one player is afk or something this plugin can auto ready them.
Problem with the original plugins was the quite annoying chat spam, that will hopefully be gone with this revision.

ConVars are the same to allow for drop in replacement:    
`mvm_autoready_threshold` - the amount of players that have to ready to force start the round    
`mvm_autoready_percent` - the ratio of players (0.0 .. 1.0) that have to ready to force start the round    
Admin Command:    
`sm_forceallready` - force all players into the ready state, starting the round. Requires the cheat admin flag.

## TDM Tickets
A small plugin for TF2 servers that implements a battlefield like ticket system for team deathmatch.
It abuses mp_tournament mode to display tickets as team names *without* actually displaying any team ready popups during WFP.
Expect things to break if you have any other plugins that use tournament mode in any way.
For those that are not familiar: Spawning with this plugin requires a ticket, and once your team runs out of tickets, you loose the round.

There is really only one ConVar:
`sm_tdm_tickets` - set the amount of tickets each team has.

## Map Props
Allows server mods to spawn and manipulate and save props using an array of commands.

In order for props to save, add this block to your databases.cfg
```
	"MapProps"
	{
		"driver" "sqlite"
		"database" "mapprops"
	}
```

Commands are as follows:
* sm_spawnprop <model> - spawns a static model
* sm_spawnphys <model> - spawns a physics model
* sm_deleteprop [ref] - deletes the ref or aimed prop
* sm_freezeprop [ref] - freezes the ref or aimed physics prop
* sm_unfreezeprop [ref] - unfreezes the ref or aimed physics prop
* sm_saveprop [ref] - add or update prop in database
* sm_removeprop [ref] - remove prop from database
* sm_propowner [ref] - shows who spawned the ref or aimed prop, if spawned with sm_spawn*
* sm_propmodel [ref] - returns the model path for the ref or aimed prop
* sm_colorprop <r> <g> <b> [a] - colors a prop. r, g, b go from 0 to 255, a is optional with a min of 50