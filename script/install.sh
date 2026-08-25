#!/bin/bash

set -e

DIR=$1
if [ "${DIR}" = "" ]; then
	DIR=/lib/modules/$(uname -r)/extra
fi

[ -e /usr/bin/install ] || exit 1
[ -e /sbin/depmod ] || [ -e /usr/sbin/depmod ] || exit 1

[ -d ${DIR} ] || /bin/mkdir -p ${DIR}

/usr/bin/install -o root -g root -m 644 ./src/sys/fs/hammer2/hammer2.ko ${DIR}
depmod -a

echo "install success"
