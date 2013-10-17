#!/bin/sh

SNAPBASE='zfs_rolling_snap'
SNAPNAME="$SNAPBASE"_`date +%Y%m%d-%H%M%S`
HOST='finwe.chchile.org'
DEST='tank'
MAXSNAP=3

rsnaps=$(mktemp -t ${0##*/})		# Remote
lsnaps=$(mktemp -t ${0##*/})		# Local
commonsnaps=$(mktemp -t ${0##*/})	# Common
trap "rm -f $rsnaps $lsnaps $commonsnaps" EXIT INT TERM

ssh $HOST zfs list -Hrt snapshot -o name "$1" | grep "@${SNAPBASE}_" | \
    sed 's/.*@//' | sort -n > $rsnaps
lastsnap=$(tail -n 1 $rsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2 << EOF

Snapshot on the remote host does not exist.  Please create it using
ssh $HOST zfs snapshot -r $1@$SNAPNAME
EOF
	exit 1
fi

zfs list -Hrt snapshot -o name "$DEST/${1#*/}" | grep "@${SNAPBASE}_" | \
    sed 's/.*@//' | sort -n > $lsnaps
comm -12 $rsnaps $lsnaps > $commonsnaps
lastsnap=$(tail -n 1 $commonsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2  << EOF

Snapshot on this system does not exist.  Please transfer it using
ssh $HOST zfs send -R $1@$lastsnap | zfs receive -d $DEST
EOF
	exit 1
fi

ssh $HOST zfs snapshot -r "$1@$SNAPNAME"
ssh $HOST zfs send -Ri "$1@$lastsnap" "$1@$SNAPNAME" | zfs receive -dF $DEST

snapcount=$(cat $commonsnaps | wc -l)
[ $snapcount -le $MAXSNAP ] && exit
for snap in $(head -n $(($snapcount - $MAXSNAP)) $commonsnaps); do
	ssh $HOST zfs destroy -r "$1@$snap"
	zfs destroy -r "$DEST/${1#*/}@$snap"
done
