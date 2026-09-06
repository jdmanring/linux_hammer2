#!/bin/sh
# WHAT A HUNG GUEST HOLDS, READ THROUGH THE QEMU GUEST AGENT.
# A guest whose task has hung in the module keeps its kernel log, its
# blocked-task list and its lockdep counters until it is reset, and ssh is
# usually gone by then, sshd's fork having touched the wedged mount. The
# guest agent has not. This runs a shell in the guest through
# `virsh qemu-agent-command` and prints its output: dmesg, `w` and `t` into
# the sysrq trigger, ps with wchan, and lockdep_stats. Nothing here touches
# a mount. The fleet scripts call it where a run's timeout expires, before
# the guest is destroyed, so the report a hang leaves is in the log.
#
#   script/guest-dmesg.sh <domain>       to stdout, exit 2 without an agent
set -u
DOM=${1:?domain}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
CMD='dmesg; echo ===sysrq-w; echo w > /proc/sysrq-trigger; echo t > /proc/sysrq-trigger; sleep 2; dmesg | tail -300; echo ===ps; ps -eo pid,ppid,stat,time,wchan:32,args | grep -v "\] *$"; echo ===lockdep; cat /proc/lockdep_stats 2>/dev/null | head -12'
esc=$(printf '%s' "$CMD" | sed 's/\\/\\\\/g; s/"/\\"/g')
r=$($VIRSH qemu-agent-command --timeout 20 "$DOM" "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",\"$esc\"],\"capture-output\":true}}" 2>&1) || { echo "guest-dmesg: COULD-NOT-RUN: no agent on $DOM: $r" >&2; exit 2; }
pid=$(printf '%s' "$r" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
[ -n "$pid" ] || { echo "guest-dmesg: COULD-NOT-RUN: guest-exec gave no pid: $r" >&2; exit 2; }
n=0
while :; do
	s=$($VIRSH qemu-agent-command --timeout 20 "$DOM" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" 2>&1) || { echo "guest-dmesg: COULD-NOT-RUN: status: $s" >&2; exit 2; }
	case $s in *'"exited":true'*) break;; esac
	sleep 1; n=$((n + 1)); [ $n -gt 60 ] && { echo "guest-dmesg: COULD-NOT-RUN: the capture itself hung" >&2; exit 2; }
done
printf '%s' "$s" | sed -n 's/.*"out-data":"\([^"]*\)".*/\1/p' | base64 -d
