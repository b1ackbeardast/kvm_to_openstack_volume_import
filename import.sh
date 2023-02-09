#!/bin/sh
set -o errexit -o pipefail

SERVER="$1"
VM="$2"
ROOT_ID="$3"
DATA_ID="$4"

log() {
  local loglevel=$2
  [ -z $loglevel ] && loglevel="INFO"
  echo "${loglevel}: $1" >&2
}

die() {
  log  "$@" ERROR
  exit 1
}

usage () {
    cat <<HELP_USAGE

    $0 hypervisor_name vm_name root_volume_id data_volume_id"

    hypervisor_name - The hypervisor from which we want to import vm to openstack.
    vm_name - VM name.
    root_volume_id - ID of the previously created empty root volume in the openstack-cinder.
    data_volume_id - ID of the previously created empty data volume in the openstack-cinder.

    Before importing vm, you need to:
    - run cloud-init clean on vm
    - create an empty instance with power_state=shutoff in openstack, with the same number(size) of disks
    - pass the volume ids of this instance to the script
    - launch an instance in openstack and check
HELP_USAGE
  exit 1
}

if [ -z "$SERVER" ] || [ -z "$VM" ] || [ -z "$ROOT_ID" ] || [ -z "$DATA_ID" ]; then
  usage
fi

log "Checking ceph client confuguration exists"
ceph_cfg="/etc/ceph/ceph.conf"
ceph_key="/etc/ceph/ceph.client.vmbar.keyring"

if ! command -v ceph &>/dev/null; then
  die "ceph client is not installed."
fi

for conf in ${ceph_cfg} ${ceph_key}; do
  if [ ! -f $conf ]; then
    die "$conf file not found."
  fi
done

log "Wait for up to 30 seconds for the guest to shut down"
remote_virsh="virsh -q -c qemu+ssh://infra@$SERVER/system"
vm_vol_type=$($remote_virsh domblklist $VM | grep hda | awk -F 'data/' '{print $2}' | awk -F '/' '{print $1}')
vm_vol_files=$($remote_virsh vol-list --pool $vm_vol_type | grep $VM | grep vol | awk '{print $2}')

$remote_virsh shutdown $VM || true
counter=0
while [ $counter -lt 30 ]; do
  vm_status=$($remote_virsh domstate $VM)
  if [ "$vm_status" == "shut off" ]; then
    break
  fi
  sleep 1
  counter=$((counter + 1))
done

vm_status=$($remote_virsh domstate $VM)
if [ "$vm_status" != "shut off" ]; then
  $remote_virsh destroy $VM || true
  sleep 10
fi

log "Download vm volumes"
for vol in $vm_vol_files; do
  rsync --progress --rsync-path="sudo rsync" infra@${SERVER}:${vol} /hdd
done

log "Renaming old RBD images"
for image in $ROOT_ID $DATA_ID; do
  rbd --id vmbar rename -p cinder_volumes_${vm_vol_type} volume-${image} back-${image}
done

log "Importing VM data to RBD"
qemu-img convert -p -f qcow2 -O raw /hdd/${VM}-root-vol-0 rbd:cinder_volumes_${vm_vol_type}/volume-${ROOT_ID}:id=vmbar:conf=${ceph_cfg}:keyring=${ceph_key}
qemu-img convert -p -f qcow2 -O raw /hdd/${VM}-data-vol-0 rbd:cinder_volumes_${vm_vol_type}/volume-${DATA_ID}:id=vmbar:conf=${ceph_cfg}:keyring=${ceph_key}
