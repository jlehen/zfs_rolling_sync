#!/bin/sh

usage() {
	[ $# -ne 0 ] && echo "Error: $*" >&2
	cat >&2 << EOF
Usage: ${0##*/} [-b snapname] [-m maxsnap] [-v] srchost::src/ds dst/ds
Example: ${0##*/} peerhost::tank/jails/myfail tank
EOF
}

: ${SNAPBASE:=zfs_rolling_sync-`hostname -s`}
: ${MAXSNAP:=3}
: ${V:=}

while getopts 'b:m:v' opt; do
	case "$opt" in
	b) SNAPBASE="$OPTARG" ;;
	m) MAXSNAP="$OPTARG" ;;
	v) V="-v" ;;
	esac
done
shift $(($OPTIND - 1))

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

zfs list -Hrt snapshot -o name "$DESTDS/${SRCDS#*/}" | \
    grep "$DESTDS/${SRCDS#*/}@${SNAPBASE}_" | sed 's/.*@//' | sort -n > $lsnaps
comm -12 $rsnaps $lsnaps > $commonsnaps
lastsnap=$(tail -n 1 $commonsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2  << EOF

Snapshot on this system does not exist.  Please transfer it using
ssh $SRCHOST zfs send -R $SRCDS@$SNAPNAME | zfs receive -d $DESTDS
EOF
	exit 1
fi

ssh $SRCHOST zfs snapshot -r "$SRCDS@$SNAPNAME"
ssh $SRCHOST zfs send $V -Ri "$SRCDS@$lastsnap" "$SRCDS@$SNAPNAME" | \
    zfs receive $V -dF $DESTDS

snapcount=$(cat $commonsnaps | wc -l)
[ $snapcount -le $MAXSNAP ] && exit
for snap in $(head -n $(($snapcount - $MAXSNAP)) $commonsnaps); do
	ssh $SRCHOST zfs destroy $V -r "$SRCDS@$snap"
	zfs destroy $V -r "$DESTDS/${SRCDS#*/}@$snap"
done
