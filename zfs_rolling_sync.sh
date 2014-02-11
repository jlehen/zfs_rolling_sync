#!/bin/sh

usage() {
	[ $# -ne 0 ] && echo "Error: $*" >&2
	cat >&2 << EOF
Usage: ${0##*/} [-b snapname] [-m maxsnap] [-t tag] [-v] srchost::src/ds dst/ds
Example: ${0##*/} peerhost::tank/jails/myjail tank
Defaults:
  snapbase: zfs_rolling_sync
  maxsnap: 3
  tag:
EOF
	exit 1
}

: ${SNAPBASE:=zfs_rolling_sync}
: ${MAXSNAP:=3}
: ${SNAPTAG:=}
: ${V:=}

while getopts 'b:m:t:v' opt; do
	case "$opt" in
	b) SNAPBASE="$OPTARG" ;;
	m) MAXSNAP="$OPTARG" ;;
	t) SNAPTAG="$OPTARG" ;;
	v) V="-v" ;;
	esac
done
shift $(($OPTIND - 1))

SNAPBASE="$SNAPBASE${SNAPTAG:+-}$SNAPTAG"
SNAPNAME="$SNAPBASE"_`date +%Y%m%d-%H%M%S`

SRCHOST="${1%%::*}"
SRCDS="${1##*::}"
DESTDS="$2"

case "$SRCHOST:$SRCDS:$DESTDS" in
:*) usage "Missing source host" ;;
*::*) usage "Missing source filesystem" ;;
*:) usage "Missing destination filesystem" ;;
esac

case "$V" in
'') V= ;;
*) V=-v ;;
esac

rsnaps=$(mktemp -t ${0##*/})		# Remote
lsnaps=$(mktemp -t ${0##*/})		# Local
commonsnaps=$(mktemp -t ${0##*/})	# Common
trap "rm -f $rsnaps $lsnaps $commonsnaps" EXIT INT TERM

ssh $SRCHOST zfs list -Hrt snapshot -o name "$SRCDS" | \
    grep "$SRCDS@${SNAPBASE}_" | sed 's/.*@//' | sort -n > $rsnaps
lastsnap=$(tail -n 1 $rsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2 << EOF

Snapshot on the remote host does not exist.  Please create it using
ssh $SRCHOST zfs snapshot -r $SRCDS@$SNAPNAME
EOF
	exit 1
fi

# Keep only snapshots name that appear on every datasets.
# When a zfs receive is interrupted, some dataset may have the latest
# snapshots while the others don't, leading to incremental transfers problems.
nds=$(zfs list -Hr -o name "$DESTDS/${SRCDS#*/}" | grep -c .)

zfs list -Hrt snapshot -o name "$DESTDS/${SRCDS#*/}" | \
    grep "@${SNAPBASE}_" | sed 's/.*@//' | sort -n | uniq -c | \
    awk '$1 == '$nds' {print $2}' > $lsnaps
comm -12 $rsnaps $lsnaps > $commonsnaps
commonsnap=$(tail -n 1 $commonsnaps)
if [ -z "$commonsnap" ]; then
	cat 1>&2  << EOF

Snapshot on this system does not exist.  Please transfer it using
ssh $SRCHOST zfs send -R $SRCDS@$lastsnap | zfs receive -d $DESTDS
EOF
	exit 1
fi

ssh $SRCHOST zfs snapshot -r "$SRCDS@$SNAPNAME"
ssh $SRCHOST zfs send $V -Ri "$SRCDS@$commonsnap" "$SRCDS@$SNAPNAME" | \
    zfs receive $V -dF $DESTDS

snapcount=$(cat $commonsnaps | wc -l)
[ $snapcount -le $MAXSNAP ] && exit
for snap in $(head -n $(($snapcount - $MAXSNAP)) $commonsnaps); do
	ssh $SRCHOST zfs destroy $V -r "$SRCDS@$snap"
	zfs destroy $V -r "$DESTDS/${SRCDS#*/}@$snap"
done
