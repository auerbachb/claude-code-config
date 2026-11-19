# presence-decision.jq — the ONE decision "is away handling in force?" for presence.sh and
# unattended.sh (issues #2293, #2294). *(library — loaded with `jq -L <lib> 'include "presence-decision"; …'`)*
#
# Two records can each say whether the operator is away: the unattended flag
# (`.unattended` = {active, since_epoch, until_epoch}) and the presence declaration
# (`.presence` = {state, declared_epoch, until_epoch, ...}). Delayed writes and `unattended.sh on|off`
# by hand can leave them disagreeing. Every reader derives its answer from `decide` below, so
# `presence.sh status|is-away|expire|return|probe` and `unattended.sh is-active|status` cannot differ.
# Do not copy these rules into another script.
#
# The rule: the NEWER declaration governs, and when neither is clearly newer the answer is AWAY.
# Wrongly denying a menu to a present operator costs a delayed question he sees on his next message;
# wrongly opening a blocking menu while he is away stalls the night.
#
#   unattended flag   presence record        governs
#   ---------------   -------------------    ------------------------------------------------------
#   on                none                   unattended (away)
#   on                here/away, ut >= pt    unattended (away; a tie is away)
#   on                away,      ut <  pt    presence (away, the presence end): a delayed `on` that
#                                            captured its epoch before a newer `set away`
#   on                here, within 3 s       unattended (away): not clearly newer
#   on                here, pt - ut > 3 s    presence (here): an older flag does not override it
#   off (explicit)    away, not ended        here (source unattended-off): ended by hand
#   off / absent      here or away           presence (an `away` with the flag absent and past its end
#                                            is not away; it needs the flag to lapse)
#   off / absent      none                   unset
#
# `decide` returns {state, source, until_epoch, declared_epoch, machine_on, lapse, away}:
#   lapse  null, or {kind, generation, until, source} for a declared window whose end passed and that
#          the operator has not answered with a message since (presence.sh return clears it); open-ended
#          windows (null end) never lapse. kind is the window's own kind: here or away.
#   away   away handling applies: an away window not yet ended, or any lapsed window.

def isnum: type == "number";
def ambiguity_seconds: 3;

def decide($p; $u; $now):
  ($p.state // "") as $ps
  | ($ps == "here" or $ps == "away") as $pv
  | ($p.declared_epoch | if isnum then . else 0 end) as $pt
  | ($u.since_epoch | if isnum then . else 0 end) as $ut
  | ($u.active == true) as $on
  | ($u.active == false) as $off
  | ($p.until_epoch | if isnum then . else null end) as $pu
  | ($u.until_epoch | if isnum then . else null end) as $uu
  | (if $on and ($pv | not) then "unattended"
     elif $on and $ut >= $pt then "unattended"
     elif $on and $ps == "away" then "presence"
     elif $on and ($pt - $ut) <= ambiguity_seconds then "unattended"
     elif $on then "presence"
     elif $pv then "presence"
     else "none" end) as $gov
  | (if $gov == "unattended" then
       {state: "away", source: "unattended", until_epoch: $uu,
        declared_epoch: ($u.since_epoch // null), machine_on: true,
        lapse: (if $uu != null and $uu <= $now
                then {kind: "away", generation: $ut, until: $uu, source: "unattended"} else null end)}
     elif $gov == "presence" then
       (if $ps == "away" and $off and ($pu == null or $pu > $now) then
          {state: "here", source: "unattended-off", until_epoch: null, declared_epoch: null,
           machine_on: true, lapse: null}
        else
          {state: $ps, source: "presence", until_epoch: $pu,
           declared_epoch: ($p.declared_epoch // null), machine_on: ($p.machine_on != false),
           lapse: (if $pu != null and $pu <= $now and ($ps == "here" or ($ps == "away" and $on))
                   then {kind: $ps, generation: $pt, until: $pu, source: "presence"} else null end)}
        end)
     else
       {state: "unset", source: "none", until_epoch: null, declared_epoch: null,
        machine_on: true, lapse: null}
     end)
  | . + {away: ((.state == "away" and ((.until_epoch == null) or .until_epoch > $now)) or .lapse != null)};
