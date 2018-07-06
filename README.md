# Auto Deploy HA Kubernetes Cluster By Kubeadm

## Prerequisites

### Software version

- Linux version: CentOS 7.4
- docker version: 17.03 and above

### OS Setting

- disable SELinux
- disable iptables and firewalld service
- ssh login without password


## Build Cluster

run below commands and setting on the first `MASTER` node

### download current repo
```
# git clone https://github.com/kulong0105/kubeadm-ha.git
```

### download k8s images

access this url: [https://pan.baidu.com/s/1gcxYJeikB5reXUtaNCYi1g](https://pan.baidu.com/s/1gcxYJeikB5reXUtaNCYi1g) and download it

### extract images to kubeadm-ha repo

```
# tar zxvf k8s-images.tar.gz -C kubeadm-ha/images --strip-components=1

```

### Update Config File

check the deploy config file `/path/to/kubeadm-ha/deploy.conf`, and update the value according to your environment
```
[renyl@localhost kubeadm-ha]$ cat deploy.conf
[IP CONFIG]
#
# Specify master nodes's IP address
# - for HA deployment, only support three nodes
# - for non-HA deployment, only support one node
#
K8S_IP_MASTER1=192.168.50.11
K8S_IP_MASTER2=192.168.50.12
K8S_IP_MASTER3=192.168.50.13

#
# Specify worker nodes's IP address
# - support zero worker node
# - no limit to number of woker nodes
#
K8S_IP_WORKER1=192.168.50.21
K8S_IP_WORKER2=192.168.50.22
K8S_IP_WORKER3=192.168.50.23



[COMMON CONFIG]
# Choose the deployment way, set 'False' to deploy Non-High Availability
HA_DEPLOYMENT=True

# Choose a specific Kubernetes version for the control plane
KUBERNETES_VERSION=v1.9.7

# The IP address the API Server will advertise it's listening on
APISERVER_ADVERTISE_ADDRESS=192.168.50.11

# Specify range of IP addresses for the pod network
POD_NETWORK_CIDR=172.168.0.0/12

# Use alternative range of IP address for service VIPs
SERVICE_CIDR=10.96.0.0/12

# Specify the IP address which calico service can access
CALICO_REACHABLE_IP=192.168.50.1

# Specify etcd data directory
ETCD_DATA_DIR=/data/etcd

# cluster will not schedule pods on the master by default, set 'true' to be able to schedule pods on the master
MASTER_SCHEDULABLE_BOOL=FALSE

# Specify k8s cert directory
KUBERNETES_CERT_DIR=/etc/kubernetes/pki

# load docker iamges when run install/add
LOAD_IMAGES_BOOL=True

# remove docker images when run uninstall/remove
REMOVE_IMAGES_BOOL=True



[HIGH AVAILABILITY CONFIG]
# Specify the IP address which keepalived service get
KEEPALIVED_VIRTUAL_IP=192.168.50.200

# Sepcify the virtual router id
KEEPALIVED_VIRTUAL_ROUTER_ID=52

# Specify the nginx listen port
NGINX_LISTEN_PORT=16433
[renyl@localhost kubeadm-ha]$
```


### deployment

```
# ./run.sh install
```

NOTE:
- run `./run.sh -h` show more details
- the full deployment log will be saved under current log dir, you can use `less -R` command to check details


## TODO

- support monitor


## refers
- https://kubernetes.io/docs/setup/independent/high-availability/
- https://coreos.com/os/docs/latest/generate-self-signed-certificates.html
- https://nginx.org/en/docs/http/load_balancing.html
- http://www.keepalived.org/doc/configuration_synopsis.html


## License
This project is licensed under the GPL v2 license
