#!/bin/bash

set -e

DIR=$1
if [ "${DIR}" = "" ]; then
	DIR=/lib/modules/$(uname -r)/extra
fi

[ ! -f ${DIR}/hammer2.ko ] || /bin/rm ${DIR}/hammer2.ko
[ ! -f ${DIR}/hammer2.ko.zst ] || /bin/rm ${DIR}/hammer2.ko.zst
depmod -a

echo "uninstall success"
