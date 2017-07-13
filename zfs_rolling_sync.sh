#!/bin/sh

usage() {
	[ $# -ne 0 ] && echo "Error: $*" >&2
	cat >&2 << EOF
Usage: ${0##*/} [options] [srchost::]src/ds [dsthost::]dst/ds
Options:
  -b snapname	Change the basename of the snapshot
  -m maxnap	Maximum number of snapshots to keep
  -t tag	Tag snapshots with this (in addition to snapbase)
  -v		Be verbose while sending/receiving datasets.
Defaults:
  snapbase: zfs_rolling_sync
  maxsnap: 3
  tag:
Example: ${0##*/} peerhost::tank/jails/myjail tank
EOF
	exit 1
}

srczfs() {
	${SRCHOST:+ssh $SRCHOST} zfs "$@"
}

dstzfs() {
	${DSTHOST:+ssh $DSTHOST} zfs "$@"
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

SRCDS="${1##*::}"
case "$1" in
*::*) SRCHOST="${1%%::*}" ;;
*) SRCHOST= ;;
esac

DSTDS="${2##*::}"
case "$2" in
*::*) DSTHOST="${2%%::*}" ;;
*) DSTHOST= ;;
esac

case "$SRCDS:$DSTDS" in
:*) usage "Missing source filesystem" ;;
*:) usage "Missing destination filesystem" ;;
esac

case "$V" in
'') V=; ECHO=: ;;
*) V=-v; ECHO=echo ;;
esac

srcsnaps=$(mktemp -t ${0##*/})		# Remote
dstsnaps=$(mktemp -t ${0##*/})		# Local
commonsnaps=$(mktemp -t ${0##*/})	# Common
trap "rm -f $srcsnaps $dstsnaps $commonsnaps" EXIT INT TERM

srczfs list -Hrt snapshot -o name "$SRCDS" | \
    grep "$SRCDS@${SNAPBASE}_" | sed 's/.*@//' | sort -n > $srcsnaps
lastsnap=$(tail -n 1 $srcsnaps)
if [ -z "$lastsnap" ]; then
	cat 1>&2 << EOF

Snapshot on the remote host does not exist.  Please create it using
${SRCHOST:+ssh $SRCHOST }zfs snapshot -r $SRCDS@$SNAPNAME
EOF
	exit 1
fi

# Keep only snapshots name that appear on every datasets.
# When a zfs receive is interrupted, some dataset may have the latest
# snapshots while the others don't, leading to incremental transfers problems.
nds=$(dstzfs list -Hr -o name "$DSTDS/${SRCDS#*/}" | grep -c .)

dstzfs list -Hrt snapshot -o name "$DSTDS/${SRCDS#*/}" | \
    grep "@${SNAPBASE}_" | sed 's/.*@//' | sort -n | uniq -c | \
    awk '$1 == '$nds' {print $2}' > $dstsnaps
comm -12 $srcsnaps $dstsnaps > $commonsnaps
commonsnap=$(tail -n 1 $commonsnaps)
if [ -z "$commonsnap" ]; then
	cat 1>&2  << EOF

Snapshot on this system does not exist.  Please transfer it using
${SRCHOST:+ssh $SRCHOST }zfs send -R $SRCDS@$lastsnap | ${DSTHOST:+ssh $DSTHOST }zfs receive -d $DSTDS
EOF
	exit 1
fi

$ECHO "===> Creating source snapshot $SRCDS@$SNAPNAME"
srczfs snapshot -r "$SRCDS@$SNAPNAME"
$ECHO "===> Transferring source snapshot to $DSTDS"
srczfs send $V -Ri "$SRCDS@$commonsnap" "$SRCDS@$SNAPNAME" | \
    dstzfs receive $V -dF $DSTDS

snapcount=$(cat $commonsnaps | wc -l)
[ $snapcount -le $MAXSNAP ] && exit
$ECHO "===> Deleteting old snapshots"
for snap in $(head -n $(($snapcount - $MAXSNAP)) $commonsnaps); do
	srczfs destroy $V -r "$SRCDS@$snap"
	dstzfs destroy $V -r "$DSTDS/${SRCDS#*/}@$snap"
done
