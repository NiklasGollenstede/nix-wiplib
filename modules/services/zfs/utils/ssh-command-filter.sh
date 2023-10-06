#!/usr/bin/env -S bash -u -o pipefail

# Used as an SSH user's (force-)command, this only allow to run »zfs list|get|receive|send« and piping through »mbuffer«. This is designed to be used on the remote side of a »syncoid« operation.
# Note that »zfs receive« can be destructive (but only if the executing user has the »destroy« permission).
# Expects the remote »syncoid« call to use »--no-command-checks«, and »--mbuffer-size« of the default »16M«.

# TODO: Allow receive and/or send as necessary. not always booth.

if [[ ! ${SSH_ORIGINAL_COMMAND:-} ]] ; then echo 'Interactive sessions are not allowed' >&2 ; exit 1 ; fi
if [[ $SSH_ORIGINAL_COMMAND == "exit" || $SSH_ORIGINAL_COMMAND == "echo -n" ]] ; then exit 0 ; fi
if [[ $SSH_ORIGINAL_COMMAND == *$'\n'* ]] ; then echo 'Refusing to run command with newline' >&2 ; exit 1 ; fi # shouldn't happen

#exec 2>>/tmp/log
#echo 'SSH_ORIGINAL_COMMAND:' >&2 ; declare -p SSH_ORIGINAL_COMMAND >&2 ; set -x

fromMbuffer=$( <<<$SSH_ORIGINAL_COMMAND grep -oP '^ *mbuffer .*?[|]' ) || true
SSH_ORIGINAL_COMMAND=${SSH_ORIGINAL_COMMAND/$fromMbuffer/}
toMbuffer=$( <<<$SSH_ORIGINAL_COMMAND grep -oP '[|] *mbuffer [^|]*$' ) || true
SSH_ORIGINAL_COMMAND=${SSH_ORIGINAL_COMMAND/$toMbuffer/}
IFS=$'\n' cmd=( $( <<<$SSH_ORIGINAL_COMMAND xargs -n1 ) ) || exit # this unquotes, but fails on newlines within quotes (but we already don't allow newlines)

# just ignore the »ps« call by the »iszfsbusy« check by »syncoid« (dunno what that is good for anyway)
if [[ ${cmd[0]} != zfs ]] ; then [[ ${cmd[0]} == ps ]] || echo 'Refusing to run anything but »zfs« as main command' >&2 ; exit 1 ; fi
if [[ ! ${cmd[1]} =~ ^(list|get|recv|receive|send)$ ]] ; then echo 'Only list, get, receive, and send zfs commands are allowed' >&2 ; exit 1 ; fi

set +x ; if [[ ${cmd[-1]} == '2>&1' ]] ; then unset cmd[-1] ; exec 2>&1 ; fi
if [[ $fromMbuffer ]] ; then
    mbuffer -q -s 128k -m 16M 2>/dev/null | "${cmd[@]}" || exit
else if [[ $toMbuffer ]] ; then
    "${cmd[@]}" | mbuffer -q -s 128k -m 16M 2>/dev/null || exit
else "${cmd[@]}" || exit ; fi ; fi
