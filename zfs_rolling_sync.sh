#!/bin/sh

: ${SNAPBASE:='zfs_rolling_snap'}
SNAPNAME="$SNAPBASE"_`date +%Y%m%d-%H%M%S`
: ${SRCHOST:='finwe.chchile.org'}
: ${DESTFS:='tank'}
: ${MAXSNAP:=3}
: ${V:=}

case "$V" in
'') V= ;;
*) V=-v ;;
esac

rsnaps=$(mktemp -t ${0##*/})		# Remote
lsnaps=$(mktemp -t ${0##*/})		# Local
commonsnaps=$(mktemp -t ${0##*/})	# Common
trap "rm -f $rsnaps $lsnaps $commonsnaps" EXIT INT TERM

ssh $SRCHOST zfs list -Hrt snapshot -o name "$1" | grep "$1@${SNAPBASE}_" | \
    sed 's/.*@//' | sort -n > $rsnaps
lastsnap=$(tail -n 1 $rsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2 << EOF

Snapshot on the remote host does not exist.  Please create it using
ssh $SRCHOST zfs snapshot -r $1@$SNAPNAME
EOF
	exit 1
fi

zfs list -Hrt snapshot -o name "$DESTFS/${1#*/}" | \
    grep "$DESTFS/${1#*/}@${SNAPBASE}_" | sed 's/.*@//' | sort -n > $lsnaps
comm -12 $rsnaps $lsnaps > $commonsnaps
lastsnap=$(tail -n 1 $commonsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2  << EOF

Snapshot on this system does not exist.  Please transfer it using
ssh $SRCHOST zfs send -R $1@$lastsnap | zfs receive -d $DESTFS
EOF
	exit 1
fi

ssh $SRCHOST zfs snapshot -r "$1@$SNAPNAME"
ssh $SRCHOST zfs send $V -Ri "$1@$lastsnap" "$1@$SNAPNAME" | \
    zfs receive $V -dF $DESTFS

snapcount=$(cat $commonsnaps | wc -l)
[ $snapcount -le $MAXSNAP ] && exit
for snap in $(head -n $(($snapcount - $MAXSNAP)) $commonsnaps); do
	ssh $SRCHOST zfs destroy $V -r "$1@$snap"
	zfs destroy $V -r "$DESTFS/${1#*/}@$snap"
done
