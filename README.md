Script for importing volumes of a virtual machine on a KVM host into openstack-cinder with ceph backend. To execute it, you need ssh access to the hypervisor and access to ceph(rbd).
My script uses `infra` user and `hdd` directory. You can change this if you wish.