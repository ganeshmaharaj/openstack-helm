#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

function sdn_lb_support_install {
  if [ "x$HOST_OS" == "xubuntu" ]; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
      bridge-utils
  elif [ "x$HOST_OS" == "xcentos" ]; then
    sudo yum install -y \
      bridge-utils
  elif [ "x$HOST_OS" == "xfedora" ]; then
    sudo dnf install -y \
      bridge-utils
  fi
}

function base_install {
  if [ "x$HOST_OS" == "xubuntu" ]; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
      iproute2 \
      iptables \
      ipcalc \
      nmap \
      lshw \
      jq \
      python-pip
  elif [ "x$HOST_OS" == "xcentos" ]; then
    sudo yum install -y \
      epel-release
    # ipcalc is in the initscripts package
    sudo yum install -y \
      iproute \
      iptables \
      initscripts \
      nmap \
      lshw \
      python-pip
    # We need JQ 1.5 which is not currently in the CentOS or EPEL repos
    sudo curl -L -o /usr/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
    sudo chmod +x /usr/bin/jq
  elif [ "x$HOST_OS" == "xfedora" ]; then
    sudo dnf install -y \
      iproute \
      iptables \
      ipcalc \
      nmap \
      lshw \
      jq \
      python-pip
  fi

  sudo -H pip install --upgrade pip
  sudo -H pip install --upgrade setuptools
  sudo -H pip install pyyaml
  sudo -H pip install yq

  if [ "x$SDN_PLUGIN" == "xlinuxbridge" ]; then
    sdn_lb_support_install
  fi

  # NOTE(portdirect): Temp workaround until module loading is supported by
  # OpenStack-Helm in Fedora
  if [ "x$HOST_OS" == "xfedora" ]; then
    sudo modprobe openvswitch
    sudo modprobe ebtables
    sudo modprobe gre
    sudo modprobe vxlan
    sudo modprobe ip6_tables
  fi
}

function json_to_yaml {
  python -c 'import sys, yaml, json; yaml.safe_dump(json.load(sys.stdin), sys.stdout, default_flow_style=False)'
}

function yaml_to_json {
  python -c 'import sys, yaml, json; json.dump(yaml.safe_load(sys.stdin), sys.stdout)'
}

function loopback_support_install {
  if [ "x$HOST_OS" == "xubuntu" ]; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends \
      targetcli \
      open-iscsi \
      lshw
    sudo systemctl restart iscsid
  elif [ "x$HOST_OS" == "xcentos" ]; then
    sudo yum install -y \
      targetcli \
      iscsi-initiator-utils \
      dbus-python \
      lshw
  elif [ "x$HOST_OS" == "xfedora" ]; then
    sudo dnf install -y \
      targetcli \
      iscsi-initiator-utils \
      dbus-python \
      lshw
  fi
}

function loopback_setup {
  ORIGINAL_DISCS=$(mktemp --suffix=.txt)
  ALL_DISCS=$(mktemp --suffix=.txt)
  NEW_DISCS=$(mktemp --directory)
  sudo rm -rf ${LOOPBACK_DIR} || true
  sudo mkdir -p ${LOOPBACK_DIR}

  COUNT=0
  IFS=','; for LOOPBACK_NAME in ${LOOPBACK_NAMES}; do
    sudo lshw -class disk > ${ORIGINAL_DISCS}
    IFS=' '
    let COUNT=COUNT+1
    LOOPBACK_DEVS=$(echo ${LOOPBACK_DEV_COUNT} | awk -F ',' "{ print \$${COUNT}}")
    LOOPBACK_SIZE=$(echo ${LOOPBACK_SIZES} | awk -F ',' "{ print \$${COUNT}}")
    for ((LOOPBACK_DEV=1;LOOPBACK_DEV<=${LOOPBACK_DEVS};LOOPBACK_DEV++)); do
      if [ "x$HOST_OS" == "xubuntu" ]; then
        sudo targetcli backstores/fileio create loopback-${LOOPBACK_NAME}-${LOOPBACK_DEV} ${LOOPBACK_DIR}/fileio-${LOOPBACK_NAME}-${LOOPBACK_DEV} ${LOOPBACK_SIZE}
      else
        sudo targetcli backstores/fileio create loopback-${LOOPBACK_NAME}-${LOOPBACK_DEV} ${LOOPBACK_DIR}/fileio-${LOOPBACK_NAME}-${LOOPBACK_DEV} ${LOOPBACK_SIZE} write_back=false
      fi
    done
    sudo targetcli iscsi/ create iqn.2016-01.com.example:${LOOPBACK_NAME}
    if ! [ "x$HOST_OS" == "xubuntu" ]; then
      sudo targetcli iscsi/iqn.2016-01.com.example:${LOOPBACK_NAME}/tpg1/portals delete 0.0.0.0 3260 || true
      sudo targetcli iscsi/iqn.2016-01.com.example:${LOOPBACK_NAME}/tpg1/portals create 127.0.0.1 3260
    else
      #NOTE (Portdirect): Frustratingly it appears that Ubuntu's targetcli wont
      # let you bind to localhost.
      sudo targetcli iscsi/iqn.2016-01.com.example:${LOOPBACK_NAME}/tpg1/portals create 0.0.0.0 3260
    fi
    for ((LOOPBACK_DEV=1;LOOPBACK_DEV<=${LOOPBACK_DEVS};LOOPBACK_DEV++)); do
      sudo targetcli iscsi/iqn.2016-01.com.example:${LOOPBACK_NAME}/tpg1/luns/ create /backstores/fileio/loopback-${LOOPBACK_NAME}-${LOOPBACK_DEV}
    done
    sudo targetcli iscsi/iqn.2016-01.com.example:${LOOPBACK_NAME}/tpg1/acls/ create $(sudo cat /etc/iscsi/initiatorname.iscsi | awk -F '=' '/^InitiatorName/ { print $NF}')
    if [ "x$HOST_OS" == "xubuntu" ]; then
      sudo targetcli iscsi/iqn.2016-01.com.example:${LOOPBACK_NAME}/tpg1 set attribute authentication=0
    fi
    sudo iscsiadm --mode discovery --type sendtargets --portal 127.0.0.1 3260
    sudo iscsiadm -m node -T iqn.2016-01.com.example:${LOOPBACK_NAME} -p 127.0.0.1:3260 -l

    sudo lshw -class disk > ${ALL_DISCS}
    # NOTE (Portdirect): Ugly subshell hack to suppress diff's exit code
    (diff --changed-group-format="%>" --unchanged-group-format="" ${ORIGINAL_DISCS} ${ALL_DISCS} > ${NEW_DISCS}/${LOOPBACK_NAME}.raw) || true
    jq -n -c -M \
      --arg devclass "${LOOPBACK_NAME}" \
      --arg device "$(awk '/bus info:/ { print $NF }' ${NEW_DISCS}/${LOOPBACK_NAME}.raw)" \
      '{($devclass): ($device|split("\n"))}' > ${NEW_DISCS}/${LOOPBACK_NAME}
    awk '/logical name:/ {print $NF}' ${NEW_DISCS}/${LOOPBACK_NAME}.raw |\
        while read line; do
            sudo parted $line mklabel gpt
        done
    rm -f ${NEW_DISCS}/${LOOPBACK_NAME}.raw
  done
  unset IFS
  jq -c -s add ${NEW_DISCS}/* | jq --arg hostname "$(hostname)" -s -M '{block_devices:{($hostname):.[]}}' > ${LOOPBACK_LOCAL_DISC_INFO}
  cat ${LOOPBACK_LOCAL_DISC_INFO}
}

function label_loopback_host {
  # label a host with names from a file generated by loopback_dev_info_to_values
  h=${1:-`hostname`}
  for n in `jq -r '.[]["name"]'`; do
    echo node ${h} supports OSD daemon ${n}
    kubectl label nodes ${h} cephosd-device-${n}=enabled
  done
}

function get_loopback_dev_host {
  # get the hostname from a loopback_local_disc_info file
  jq -r '.["block_devices"]|keys[0]'
}

function merge_loopback_values {
  # merge the output of multiple loopback_dev_info_to_values calls,
  # eliminating duplicate-named entries.
  jq -s 'add | unique_by(.name)|{block_devices: [.[]]}'
}

function loopback_dev_info_to_values {
  # convert the device list into something that can be dumped into values.yaml
  #
  # journal devices are assigned sequentially to OSD devices, and the resulting
  # item is named by concatenating OSD and journal device name.  That way, if
  # different hosts end up with journals/OSDs at different locations, they get
  # different pods.
  #
  # This assumes the cephosd and cephjournal lists are of equal length.  It
  # will likely fail spectacularly if there are fewer journals than OSDs.
  h=${1:-`hostname`}
  jq  --arg hostname ${h} -r '[.["block_devices"][($hostname)]["cephosd"],
                               .["block_devices"][($hostname)]["cephjournal"]]|
                               transpose|
                               [.[]|
                               {name: ((.[0]|gsub("[@:\\.]";"-"))+("-j-")+(.[1]|gsub("[@:\\.]";"-"))),
                                device: (.[0]),
                                journal: {device: (.[1])},
                                type: "device",
                                zap: "1" }]'
}

function loopback_dev_info_collect {
  # each gate node creates a set of loopback iSCSI devices, and
  # produces a list of these devices in ${LOOPBACK_LOCAL_DISC_INFO}.
  # This function collects all those lists and assembles them into
  # a single values.yaml file containing a block_devices section.
  # The implementation here is more general than it needs to be,
  # as the way we're constructing thet loopback devices more-or-less
  # ensures that the SCSI addresses will be the same on every node.
  # However, this is useful as a model for constructing that section
  # in the more general case.
  DEV_INFO_DIR=$(mktemp --dir)
  VALUES_DIR=$(mktemp --dir)
  h=$(hostname)
  cat ${LOOPBACK_LOCAL_DISC_INFO} > ${DEV_INFO_DIR}/${h}
  loopback_dev_info_to_values < ${DEV_INFO_DIR}/${h} > ${VALUES_DIR}/${h}

  if [ "x$INTEGRATION" == "xmulti" ]; then
    for SUB_NODE in $SUB_NODE_IPS ; do
      ssh-keyscan "${SUB_NODE}" >> ~/.ssh/known_hosts
      ssh -i ${SSH_PRIVATE_KEY} $(whoami)@${SUB_NODE} cat ${LOOPBACK_LOCAL_DISC_INFO} > ${DEV_INFO_DIR}/${SUB_NODE}
      h=`get_loopback_dev_host < ${DEV_INFO_DIR}/${SUB_NODE}`
      echo Generating loopback device values file for node ${h}@${SUB_NODE}
      loopback_dev_info_to_values < ${DEV_INFO_DIR}/${SUB_NODE} > ${VALUES_DIR}/${h}
    done
  fi

  for h in ${VALUES_DIR}/*; do
    label_loopback_host `basename ${h}` < ${h}
  done

  cat ${VALUES_DIR}/* | merge_loopback_values | json_to_yaml > ${LOOPBACK_DEV_YAML}
  cat ${LOOPBACK_DEV_YAML}
}

function ceph_support_install {
  if [ "x$HOST_OS" == "xubuntu" ]; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends -qq \
      ceph-common
  elif [ "x$HOST_OS" == "xcentos" ]; then
    sudo yum install -y \
      ceph-common
  elif [ "x$HOST_OS" == "xfedora" ]; then
    sudo dnf install -y \
      ceph
  fi
  sudo modprobe rbd
}

function nfs_support_install {
  if [ "x$HOST_OS" == "xubuntu" ]; then
    sudo apt-get update -y
    sudo apt-get install -y --no-install-recommends -qq \
      nfs-common
  elif [ "x$HOST_OS" == "xcentos" ]; then
    sudo yum install -y \
      nfs-utils
  elif [ "x$HOST_OS" == "xfedora" ]; then
    sudo dnf install -y \
      nfs-utils
  fi
}

function gate_base_setup {
  # Install base requirements
  base_install

  # Install and setup iscsi loopback devices if required.
  if [ "x$LOOPBACK_CREATE" == "xtrue" ]; then
    echo Ceph loopback support already completed
  fi

  # Install support packages for pvc backends
  if [ "x$PVC_BACKEND" == "xceph" ]; then
    ceph_support_install
  elif [ "x$PVC_BACKEND" == "xnfs" ]; then
    nfs_support_install
  fi
}
