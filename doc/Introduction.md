# Introduction

## architecture

| role | components |
| ---| ---|
| master1| keepalived, nginx, kube-apiserver, kube-scheduler, kube-proxy, kube-dns, kubelet, calico |
| master2| keepalived, nginx, kube-apiserver, kube-scheduler, kube-proxy, kube-dns, kubelet, calico |
| master3| keepalived, nginx, kube-apiserver, kube-scheduler, kube-proxy, kube-dns, kubelet, calico |
| workers| kubelet, kube-proxy |

- keepalived: cluster config a virtual IP address, this virtual IP address point to master nodes
- nginx: as the load balancer for master nodes's apiserver
- kube-apiserver: exposes the Kubernetes API, the front-end for the Kubernetes control plane
- etcd: is used as Kubernetes’ backing store, All cluster data is stored there
- kube-scheduler: watches newly created pods that have no node assigned, and selects a node for them to run on
- kube-controller-manager: runs controllers, which are the background threads that handle routine tasks in the cluster
- kubelet: is the primary node agent, watch for pods that have been assigned to its node
- kube-proxy: enables the Kubernetes service abstraction by maintaining network rules on the host and performing connection forwarding


## version

| component | version |
| --- | --- |
| kubeadm | 1.9.7 |
| kubectl | 1.9.7 |
| calico | 3.1.1 |
| etcd | 3.1.14 |
| dashboard | 1.8.3 |
| heapster | 1.5.3 |


## features

- one-click deployment
- support non-HA and HA deployment
- support add/remove worker node

