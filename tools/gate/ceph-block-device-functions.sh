#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -ex

export WORK_DIR=$(pwd)
source ${WORK_DIR}/tools/gate/vars.sh
source ${WORK_DIR}/tools/gate/funcs/common.sh
source ${WORK_DIR}/tools/gate/funcs/network.sh
source ${WORK_DIR}/tools/gate/funcs/helm.sh
source ${WORK_DIR}/tools/gate/funcs/kube.sh


function iscsi_loopback_create {
  # create a new, local, file-backed iSCSI device and connect
  # to it.  Prints block device name, IQN details, and the SCSI address of the
  # initiator-side device, like this:
  # /dev/sda ip-127.0.0.1:3260-iscsi-iqn.2017-12.org.openstack.openstack-helm:cephosd-lun-0 2:0.0.0
  # LOOPBACK_NAME is used as the IQN unique name component.
  # LOOPBACK_SIZE is as accepted by targetcli: bytes, with an optional [K,M,G,T] suffix.
  local LOOPBACK_NAME=$1
  local LOOPBACK_SIZE=$2

  LOOPBACK_DIR=${LOOPBACK_DIR:-/tmp}

  if [ ! -d "${LOOPBACK_DIR}" ]; then
    mkdir -p ${LOOPBACK_DIR}
  fi

  # targetcli is spammy on stdout.  send its output to stderr.
  {
    local LOOPBACK_DEV=`sudo targetcli ls /iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/luns/ 2>/dev/null|grep 'lun[0-9]'|wc -l`
    local BACKSTORE=`mktemp -p ${LOOPBACK_DIR} ${LOOPBACK_NAME}.${LOOPBACK_DEV}.XXXXXXXXXX`
    local BSNAME=`basename ${BACKSTORE}`

    if [ "x$HOST_OS" == "xubuntu" ]; then
      sudo targetcli backstores/fileio create ${BSNAME} ${BACKSTORE} ${LOOPBACK_SIZE}
    else
      sudo targetcli backstores/fileio create ${BSNAME} ${BACKSTORE} ${LOOPBACK_SIZE} write_back=false
    fi

    # we'll do these repeatedly, but they're idempotent and fairly cheap.
    sudo targetcli iscsi/ create iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}
    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/portals create 0.0.0.0 3260
    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/acls/ create `sudo cat /etc/iscsi/initiatorname.iscsi | awk -F '=' '/^InitiatorName/ { print $NF}'`
    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1 set attribute authentication=0

    sudo targetcli iscsi/iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}/tpg1/luns/ create /backstores/fileio/${BSNAME}
    yes | sudo targetcli saveconfig
    sudo iscsiadm -m discovery -t sendtargets -p 127.0.0.1 3260
    sudo iscsiadm -m node -T iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME} -p 127.0.0.1:3260 -l
    sudo iscsiadm -m node -T iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME} -R

    # it takes a moment for udev to get around to creating the block device.
    sudo udevadm settle
    BLOCKDEV=`readlink -f /dev/disk/by-path/ip-127.0.0.1:3260-iscsi-iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}-lun-${LOOPBACK_DEV}`
    sudo parted -s ${BLOCKDEV} mklabel gpt
    BLOCKNAM=`basename ${BLOCKDEV}`
    # seems like we need to wait for udev again after writing the disklabel.
    sudo udevadm settle
    SCSIDEV=`readlink -f /sys/block/${BLOCKNAM}/device`
  } 1>&2
  # existing code expects scsi devices in the form bus:x.y.x, but
  # we have bus:x:y:z.  Fix that up.
  echo ${BLOCKDEV} \
       "ip-127.0.0.1:3260-iscsi-iqn.2017-12.org.openstack.openstack-helm:${LOOPBACK_NAME}-lun-${LOOPBACK_DEV}" \
       `basename ${SCSIDEV}|awk -F: '{print $1":"$2"."$3"."$4}'`
  [ -b ${BLOCKDEV} ]
}

function ceph_devicepair_create {
  # create one or more {OSD, journal} device pairs.
  # takes OSD size, journal size (both in M), and number to create,
  # ie: ceph_devicepair_create 128000 5120 3
  # produces output like this:
  #
  # {
  #  "hostname": "host1",
  #  "block_devices": [
  #   {
  #    "device": "scsi@7:0.0.0",
  #    "journal": {
  #      "device": "scsi@8:0.0.0"
  #    },
  #    "name": "scsi-7-0-0-0-j-8-0-0-0",
  #    "type": "device"
  #   },
  #   [...]
  #  ]
  # }

  # add 2M to disk sizes to make (probably excessive) room for a partition table.
  local OSD_SIZE=`expr $1 + 2`
  local JOURNAL_SIZE=`expr $2 + 2`
  local N_OSDS=${3:-1}

  (
    while [ $N_OSDS -gt 0 ]; do
      local OSD_DEV=`iscsi_loopback_create cephosd "${OSD_SIZE}M"|awk '{print $NF}'`
      local JOURNAL_DEV=`iscsi_loopback_create cephjournal "${JOURNAL_SIZE}M" | awk '{print $NF}'`
       echo '[{"device": "scsi@'${OSD_DEV}'",'\
               '"journal": {"device": "scsi@'${JOURNAL_DEV}'"},'\
               '"name": "scsi-'`echo ${OSD_DEV}|tr ":." "-"`'-j-'`echo ${JOURNAL_DEV}|tr ":." "-"`'",'\
               '"type": "device"}]'
       N_OSDS=`expr $N_OSDS - 1`
    done
  )|jq --arg hostname `hostname` -s 'add|{"hostname": ($hostname), "block_devices": [.[]]}'
}

function ceph_merge_device_values {
  # given a possibly-overlapping set of json block device lists
  # as created by ceph_loopback_devicepair_create, produce a list
  # uniqified by name.
  jq  -s '{"block_devices": [.[]["block_devices"]]|add|unique_by(.name)}' $*|\
   json_to_yaml
}

function ceph_label_device_hosts {
  # given a block device list as created by ceph_loopback_devicepair_create,
  # label its host for the OSDs it supports.
  jq -r '.block_devices[].hostname=.hostname|.block_devices|.[]| .hostname +" cephosd-device-"+.name +"=enabled"' $* |\
   xargs -l kubectl label nodes
}

sc=$0
fn=$1
shift;

case ${fn} in
  "ceph_label_device_hosts")
    ceph_label_device_hosts $*
    ;;
  "ceph_merge_device_values")
    ceph_merge_device_values $*
    ;;
 "ceph_device_pair_create")
    ceph_devicepair_create $*
    ;;
 "iscsi_loopback_create")
    iscsi_loopback_create $*
    ;;
 *)
    echo "usage: ${sc} [iscsi_loobpack_create|ceph_devicepair_create|ceph_merge_device_values|ceph_label_device_hosts]"
    ;;
esac
