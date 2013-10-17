#!/bin/sh

SNAPBASE='zfs_rolling_snap'
SNAPNAME="$SNAPBASE"_`date +%Y%m%d-%H%M%S`
HOST='finwe.chchile.org'
DEST='tank'

rsnaps=$(ssh $HOST zfs list -Hrt snapshot -o name "$1" | grep "@${SNAPBASE}_")
if [ -z "$rsnaps" ]; then
	cat 1>&2 << EOF
Snapshot on the remote host does not exist.  Please create it using
ssh $HOST zfs snapshot -r $1@$SNAPNAME
EOF
	exit 1
fi
lastsnap=`echo "$rsnaps" | sort -n | tail -n 1`

zfs list -Hrt snapshot "$DEST/${1#*/}" 2>/dev/null | grep "@${SNAPBASE}_" >/dev/null
if [ $? -ne 0 ]; then
	cat 1>&2  << EOF
Snapshot on this system does not exist.  Please transfer it using
ssh $HOST zfs send -R $lastsnap | zfs receive -d $DEST
EOF
	exit 1
fi

ssh $HOST zfs snapshot -r "$1@$SNAPNAME"
ssh $HOST zfs send -Ri $lastsnap "$1@$SNAPNAME" | zfs receive -dF $DEST
