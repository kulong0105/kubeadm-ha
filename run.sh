#!/bin/bash

usage()
{
    cat >&2 <<-EOF

Usage:
    $0 install
    $0 uninstall
    $0 add worker_node_ip
    $0 remove worker_node_ip

Options:
    install:    install kuberneters cluster
    uninstall:  uninstall kubernetes cluster
    add:        add one worker node to kubernetes cluster
    remove:     remove one worker node from kubernetes cluster

Examples:
    $0 install
    $0 uninstall
    $0 add 192.168.50.24
    $0 remove 192.168.50.25

EOF
    exit 1
}

log_info()
{
    echo >&2
    echo -e "\\x1b[1;36m[$(date +%F:%T) INFO]: $*\\x1b[0m" >&2
}

log_warn()
{
    echo >&2
    echo -e "\\x1b[1;33m[$(date +%F:%T) WARNING]: $*\\x1b[0m" >&2
}

log_error()
{
    echo >&2
    echo -e "\\x1b[1;31m[$(date +%F:%T) ERROR]: $* \\x1b[0m" >&2
}

check_files_exist()
{
    local files="$@"

    for file in $files; do
        [[ -s $file ]] || {
            log_error "cannot find file: $file"
            return 1
        }
    done
}

check_directories_exist()
{
    local directories="$@"

    for directory in $directories; do
        [[ -d "$directory" ]] || {
            log_error "cannot find a directory: $directory"
            return 1
        }

        [[ $(ls -A "$directory") ]] || {
            log_error "cannot find valid files in $directory, it's null"
            return 1
        }
    done
}

check_command()
{
    local cmd="$1"

    command -v "$cmd" &>/dev/null || {
        log_error "please install $cmd command"
        return 1
    }
}

check_ssh_port()
{
    local ip="$1"

    nmap -sn -n $ip | grep 'Host is up' > /dev/null  || {
        log_error "cannot access node $ip! Please fix this and try again"
        return 1
    }

    if nmap -p22 -n $ip | grep "22/tcp" | grep -q "closed"; then
        log_error "SSH service of IP $ip is closed! Please fix this and try again"
        return 1
    fi
}

check_ssh_login()
{
    local ip="$1"

    # must be set --foreground option, or cannot work well on CentOS7.2
    if timeout --help | grep -q "\--foreground"; then
        timeout --foreground 10 $SSH $ip "echo &>/dev/null" || {
            log_error "failed to ssh node $ip without password"
            return 1
        }
    else
        timeout 10 $SSH $ip "echo &>/dev/null" || {
            log_error "failed to ssh node $ip without password"
            return 1
        }
    fi
}

check_selinux_config()
{
    local ip="$1"

    if $SSH $ip "[[ $(getenforce) = \"Enforcing\" ]]"; then
        log_error "SELinux should be disabled in $ip"
        return 1
    fi
}

check_docker_status()
{
    local ip="$1"
    
    $SSH $ip "[[ \"$(systemctl is-active docker)\" = \"active\" ]]" || {
        log_error "docker is not running in $ip"
        return 1
    }
}

parse_deploy_config()
{
    log_info "parsing config file ..."

    local deploy_config_file="$K8S_SRC/deploy.conf"
    check_files_exist "$deploy_config_file" || return

    while read -r line; do

        echo $line | grep -q -e "^#" -e "^$" -e "^\[" && continue

        # here not use local to define, since will use these var in other function
        var=$(echo $line | cut -f1 -d"=")
        value=$(echo $line | cut -f2 -d"=")
        export $var=$value

    done < $deploy_config_file

}

check_deploy_config()
{
    log_info "checking config file ..."

    case $ACTION in
        install)
            local deploy_config_file="$K8S_SRC/deploy.conf"
            check_files_exist "$deploy_config_file" || return

            K8S_IP_MASTERS=$(grep -v -e "^#" $deploy_config_file  | grep K8S_IP_MASTER | cut -f2 -d"=")
            K8S_IP_WORKERS=$(grep -v -e "^#" $deploy_config_file  | grep K8S_IP_WORKER | cut -f2 -d"=")

            if [[ $HA_DEPLOYMENT = "True" ]]; then
                (( $(echo "$K8S_IP_MASTERS" | wc -l) == 3 )) || {
                    log_error "only support three master nodes for High Available Deployment"
                    return 1
                }
            else
                (( $(echo "$K8S_IP_MASTERS" | wc -l) == 1 )) || {
                    log_error "only support one master node for Non-High Available Deployment"
                    return 1
                }
            fi
            ;;
        add)
            local installed_ip="$K8S_SRC/.installed_ip"
            check_files_exist "$installed_ip" || return

            grep -q -w $ADD_IP_WORKER $installed_ip && {
                log_error "added ip $ADD_IP_WORKER have been in current kubernetes cluster"
                return 1
            }

            K8S_IP_MASTERS=$(grep "MASTER" $installed_ip  | awk '{print $2}')
            K8S_IP_WORKERS=$ADD_IP_WORKER
            ;;
        remove)
            local installed_ip="$K8S_SRC/.installed_ip"
            check_files_exist "$installed_ip" || return

            grep -q -w $REMOVE_IP_WORKER $installed_ip || {
                log_error "removed ip $REMOVE_IP_WORKER is not in current kubernetes cluster"
                return 1
            }

            K8S_IP_MASTERS=$(grep "MASTER" $installed_ip  | awk '{print $2}')
            K8S_IP_WORKERS=$REMOVE_IP_WORKER
            ;;
        uninstall)
            local installed_ip="$K8S_SRC/.installed_ip"
            check_files_exist "$installed_ip" || return

            K8S_IP_MASTERS=$(grep "MASTER" $installed_ip  | awk '{print $2}')
            K8S_IP_WORKERS=$(grep "WORKER" $installed_ip  | awk '{print $2}')
            ;;
   esac
}

check_nodes_status()
{
    log_info "checking nodes status ..."

    local ips="$1"
    for ip in $ips; do
        check_ssh_port $ip || return
        check_ssh_login $ip || return
        check_selinux_config $ip || return
        check_docker_status $ip || return
    done
}

yum_install_pkg()
{
    local pkg="$1"
    local ips="$2"
    local ips_num=$(echo "$ips" | wc -w)

    $PSSH -H "$ips" -p $ips_num "yum install -y $pkg" || {
        log_error "failed to install $pkg package"
        return 1
    }
}

yum_remove_pkg()
{
    local pkg="$1"
    local ips="$2"
    local ips_num=$(echo "$ips" | wc -w)

    $PSSH -H "$ips" -p $ips_num "yum remove -y $pkg" || {
        log_error "failed to remove $pkg package"
        return 1
    }
}

install_k8s_pkg()
{
    log_info "installing k8s pkgs ..."

    check_directories_exist "$K8S_SRC/yum" || return

    local ips="$1"
    local ips_num=$(echo "$ips" | wc -w)

    $PSSH -H "$ips" -p $ips_num "mkdir -p /tmp/k8s_pkg/" &>/dev/null || return
    $PSCP -H "$ips" -p $ips_num -r $K8S_SRC/yum/* /tmp/k8s_pkg/ &>/dev/null || return
    $PSSH -H "$ips" -p $ips_num "yum install -y /tmp/k8s_pkg/kube*" || {
        log_error "failed to install kubeadm pkgs"
        return 1
    }
}

remove_k8s_pkg()
{
    log_info "removing k8s pkgs ..."

    local ips="$1"
    local ips_num=$(echo "$ips" | wc -w)

    $PSSH -H "$ips" -p $ips_num "yum remove -y \"kube*\"" || return
}

stop_disable_service()
{
    local service="$1"
    local ips="$2"

    local ips_num=$(echo "$ips" | wc -w)

    $PSSH -H "$ips" -p $ips_num "systemctl stop $service" &>/dev/null
    $PSSH -H "$ips" -p $ips_num "systemctl disable $service" &>/dev/null
}

start_enable_service()
{
    local service="$1"
    local ips="$2"

    local ips_num=$(echo "$ips" | wc -w)

    $PSSH -H "$ips" -p $ips_num "systemctl daemon-reload" &>/dev/null

    $PSSH -H "$ips" -p $ips_num "systemctl restart $service" || {
        log_error "failed to restart $service service"
        return 1
    }

    $PSSH -H "$ips" -p $ips_num "systemctl enable $service" || {
        log_error "failed to enable $service service"
        return 1
    }
}

get_hostname_by_ip()
{
    local ip="$1"
    [[ $ip ]] || return 0

    $SSH $ip "hostname"
}

get_interface_by_ip()
{
    local ip="$1"
    [[ $ip ]] || return 0

    $SSH $ip "ip a | grep $ip | awk '{print \$NF}'"
}

disable_swap()
{
    log_info "disable swap ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)
    $PSSH -H "$ips" -p $ips_num "swapoff -a" >/dev/null || {
        log_error "failed to turn off swap"
        return 1
    }

    $PSSH -H "$ips" -p $ips_num "sed -i \"s#.*swap.*#\#\0#\" /etc/fstab" &>/dev/null

    return 0
}

restore_swap()
{
    log_info "enable swap ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)
    $PSSH -H "$ips" -p $ips_num "swapon -a"
    $PSSH -H "$ips" -p $ips_num "sed -i -e \"s/^#\(.*\) swap/\1 swap/\" /etc/fstab" &> /dev/null

    return 0
}

enable_bridge_nf_call()
{
    log_info "enable bridge nf call ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)

    local sysctl_k8s_conf="/tmp/k8s.conf"
    cat <<EOF > $sysctl_k8s_conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

    $PSCP -H "$ips" -p $ips_num -r $sysctl_k8s_conf /etc/sysctl.d/ >/dev/null || return
    $PSSH -H "$ips" -p $ips_num "sysctl -p /etc/sysctl.d/k8s.conf" >/dev/null || return
}

update_k8s_config()
{
    log_info "update kubelet config ..."

    local ips="$1"
    local ips_num=$(echo $ips | wc -w)

    local kubelet_config_file="/etc/systemd/system/kubelet.service.d/10-kubeadm.conf"

    $PSSH -H "$ips" -p $ips_num "sed -i \"s#cgroup-driver=.*#cgroup-driver=cgroupfs\\\"#\" $kubelet_config_file" || {
        log_error "failed to update cgroup driver"
        return 1
    }

#   $PSSH -H "$ips" -p $ips_num "sed -i '2 i Environment="KUBELET_EXTRA_ARGS=--feature-gates=DevicePlugins=true"' $kubelet_config_file" || return

    start_enable_service "kubelet" "$ips" || return
}

generate_etcd_cert()
{
    log_info "generate etcd cert ..."

    local cfssl_file="$K8S_SRC/pkgs/cfssl"
    local cfssljson_file="$K8S_SRC/pkgs/cfssljson"
    check_files_exist "$cfssl_file" "$cfssljson_file" || return

    local ca_config_json="$K8S_SRC/config/cert/ca-config.json"
    local ca_csr_json="$K8S_SRC/config/cert/ca-csr.json"
    local client_json="$K8S_SRC/config/cert/client.json"
    local config_json="$K8S_SRC/config/cert/config.json"

    local etcd_cert_dir="/etc/kubernetes/pki/etcd"
    local temp_cert_dir="/tmp/cert_dir"
    mkdir -p $temp_cert_dir || return

    # generate ca cert
    $cfssl_file gencert -initca $ca_csr_json | $cfssljson_file -bare $temp_cert_dir/ca || {
        log_error "failed to generate ca cert"
        return 1
    }

    # generate client cert
    $cfssl_file gencert \
        -ca=$temp_cert_dir/ca.pem \
        -ca-key=$temp_cert_dir/ca-key.pem \
        -config=$ca_config_json \
        -profile=client \
        $client_json | $cfssljson_file -bare $temp_cert_dir/client || {
            log_error "failed to generate client cert"
            return 1
        }

    # update config_json's hostname and ip info
    local node_hostname
    local temp_config_json="/tmp/etcd_config.json"

    for ip in $K8S_IP_MASTERS; do

        node_hostname=$(get_hostname_by_ip $ip)
        sed -e "s#\$hostname#$node_hostname#" -e "s#\$ip#$ip#" $config_json >$temp_config_json || return

        # generate server cert
        $cfssl_file gencert \
            -ca=$temp_cert_dir/ca.pem \
            -ca-key=$temp_cert_dir/ca-key.pem \
            -config=$ca_config_json \
            -profile=server \
            $temp_config_json | $cfssljson_file -bare $temp_cert_dir/server || {
                log_error "failed to generate server cert for $ip"
                return 1
            }

        # generate peer cert
        $cfssl_file gencert \
            -ca=$temp_cert_dir/ca.pem \
            -ca-key=$temp_cert_dir/ca-key.pem \
            -config=$ca_config_json \
            -profile=peer \
            $temp_config_json | $cfssljson_file -bare $temp_cert_dir/peer || {
                log_error "failed to generate peer cert for $ip"
                return 1
            }

        $SSH $ip "mkdir -p $etcd_cert_dir" || return
        $SCP $temp_cert_dir/* $ip:$etcd_cert_dir || return
    done
}

single_config_etcd()
{
    log_info "config etcd ..."

    local etcd_service_file="$K8S_SRC/config/etcd/etcd.service"
    local etcd_binary_file="$K8S_SRC/pkgs/etcd"
    check_files_exist "$etcd_service_file" "$etcd_binary_file" || return

    # etcd service will use this file to startup
    cp -a $etcd_binary_file /usr/local/bin/  || return

    # update etcd.service file's hostname,ip,data_dir info
    local temp_etcd_service_file="/tmp/etcd.service"
    sed -e "s#\$hostname#$(hostname)#" \
        -e "s#\$ip#$K8S_IP_MASTER1#" \
        -e "s#\$etcd_data_dir#$ETCD_DATA_DIR#" \
        $etcd_service_file > $temp_etcd_service_file || return

   cp -a $temp_etcd_service_file /etc/systemd/system || return

   start_enable_service "etcd" "$K8S_IP_MASTER1"
}

ha_config_etcd()
{
    log_info "config etcd ..."

    local etcd_service_file="$K8S_SRC/config/etcd/ha_etcd.service"
    local etcd_binary_file="$K8S_SRC/pkgs/etcd"
    check_files_exist "$etcd_service_file" "$etcd_binary_file" || return

    local ip_master1="$K8S_IP_MASTER1"
    local hostname_master1=$(get_hostname_by_ip $ip_master1)

    local ip_master2="$K8S_IP_MASTER2"
    local hostname_master2=$(get_hostname_by_ip $ip_master2)

    local ip_master3="$K8S_IP_MASTER3"
    local hostname_master3=$(get_hostname_by_ip $ip_master3)


    # update etcd.service file for various info
    local hostname_master
    local ip_master
    local temp_etcd_service_file="/tmp/etcd.service"

    for ip in $K8S_IP_MASTERS; do
        hostname_master=$(get_hostname_by_ip $ip)
        ip_master=$ip

        sed -e "s#\$etcd_data_dir#$ETCD_DATA_DIR#" \
            -e "s#\$hostname_master1#$hostname_master1#" \
            -e "s#\$hostname_master2#$hostname_master2#" \
            -e "s#\$hostname_master3#$hostname_master3#" \
            -e "s#\$hostname_master#$hostname_master#" \
            -e "s#\$ip_master1#$ip_master1#" \
            -e "s#\$ip_master2#$ip_master2#" \
            -e "s#\$ip_master3#$ip_master3#" \
            -e "s#\$ip_master#$ip_master#" \
            $etcd_service_file > $temp_etcd_service_file || return

        $SCP $temp_etcd_service_file $ip:/etc/systemd/system || return
        $SCP $etcd_binary_file $ip:/usr/local/bin/ || return
    done

    start_enable_service "etcd" "$K8S_IP_MASTERS" || return
}

remove_etcd()
{
    log_info "removing etcd ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    for ip in $ips; do
        stop_disable_service "etcd" "$ip"
        $SSH $ip "rm -rf /usr/local/bin/etcd $ETCD_DATA_DIR"
    done
}

ha_config_keepalived()
{
    log_info "config keepalived ..."

    local keepalived_config_file="$K8S_SRC/config/keepalived/keepalived.conf"
    local keepalived_script_file="$K8S_SRC/config/keepalived/check_alived.sh"
    check_files_exist "$keepalived_config_file" "$keepalived_script_file" || return

    yum_install_pkg "keepalived" "$K8S_IP_MASTERS" || return

    local node_interface
    local priority=100
    local role="MASTER"

    # update keepalived check script file
    local temp_check_alived_script="/tmp/check_alived.sh"
    sed -e "s#\$keepalived_virtual_ip#$KEEPALIVED_VIRTUAL_IP#" $keepalived_script_file > $temp_check_alived_script || return

    # copy to all app nodes
    local ips_num=$(echo $K8S_IP_MASTERS | wc -w)
    $PSCP -H "$K8S_IP_MASTERS" -p $ips_num -r $temp_check_alived_script /etc/keepalived/ >/dev/null || return

    # update keepalived config file
    local temp_keepalived_config_file="/tmp/keepalived.conf"
    for ip in $K8S_IP_MASTERS; do
        node_interface=$(get_interface_by_ip $ip)

        sed -e "s#\$interface#$node_interface#" \
            -e "s#\$role#$role#" \
            -e "s#\$priority#$priority#" \
            -e "s#\$keepalived_virtual_router_id#$KEEPALIVED_VIRTUAL_ROUTER_ID#" \
            -e "s#\$keepalived_virtual_ip#$KEEPALIVED_VIRTUAL_IP#" \
            $keepalived_config_file > $temp_keepalived_config_file || return

        priority=$(( $priority - 1))
        role="BACKUP"

        $SCP $temp_keepalived_config_file $ip:/etc/keepalived/ > /dev/null || return
    done

    start_enable_service "keepalived" "$K8S_IP_MASTERS" || return
}

ha_remove_keepalived()
{
    log_info "removing keepalived ..."

    stop_disable_service "keepalived" "$K8S_IP_MASTERS"
    yum_remove_pkg "keepalived" "$K8S_IP_MASTERS"
}

ha_config_nginx()
{
    log_info "config nginx ..."

    local nginx_config_file="$K8S_SRC/config/nginx/nginx.conf"
    check_files_exist "$nginx_config_file" || return

    yum_install_pkg "nginx" "$K8S_IP_MASTERS" || return

    local ip_master1="$K8S_IP_MASTER1"
    local ip_master2="$K8S_IP_MASTER2"
    local ip_master3="$K8S_IP_MASTER3"

    # update nginx config file
    local temp_nginx_config_file="/tmp/nginx.conf"
    sed -e "s#\$ip_master1#$ip_master1#" \
        -e "s#\$ip_master2#$ip_master2#" \
        -e "s#\$ip_master3#$ip_master3#" \
        -e "s#\$nginx_listen_port#$NGINX_LISTEN_PORT#" \
        $nginx_config_file > $temp_nginx_config_file || return

    local ips_num=$(echo $K8S_IP_MASTERS | wc -w)
    $PSCP -H "$K8S_IP_MASTERS" -p $ips_num -r $temp_nginx_config_file /etc/nginx/ >/dev/null || return

    start_enable_service "nginx" "$K8S_IP_MASTERS" || return

}

ha_remove_nginx()
{
    log_info "removing nginx ..."

    stop_disable_service "nginx" "$K8S_IP_MASTERS"
    yum_remove_pkg "nginx" "$K8S_IP_MASTERS"
}

load_master_images()
{
    log_info "loading master images ..."

    [[ "$LOAD_IMAGES_BOOL" = "True" ]] || return 0

    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)
    local master_images_dir="$K8S_SRC/images/master"
    check_directories_exist "$master_images_dir" || return

    $PSSH -H "$ips" -p $ips_num "mkdir -p /tmp/k8s-images" >/dev/null || return
    $PSCP -H "$ips" -p $ips_num -r $master_images_dir/* /tmp/k8s-images || {
        log_error "failed to scp images pkg to $ips"
        return 1
    }

    $PSSH -H "$ips" -p $ips_num "cd /tmp/k8s-images; for image in \$(ls); do docker load -i \$image; done" >/dev/null || return
    $PSSH -H "$ips" -p $ips_num "rm -rf /tmp/k8s-images" >/dev/null || return
}

load_worker_images()
{
    log_info "loading worker images ..."

    [[ "$LOAD_IMAGES_BOOL" = "True" ]] || return 0

    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)
    local worker_images_dir="$K8S_SRC/images/worker"
    check_directories_exist "$worker_images_dir" || return

    $PSSH -H "$ips" -p $ips_num "mkdir -p /tmp/k8s-images" >/dev/null || return
    $PSCP -H "$ips" -p $ips_num -r $worker_images_dir/* /tmp/k8s-images || {
        log_error "failed to scp images pkg to $ips"
        return 1
    }

    $PSSH -H "$ips" -p $ips_num "cd /tmp/k8s-images; for image in \$(ls); do docker load -i \$image; done" >/dev/null || return
    $PSSH -H "$ips" -p $ips_num "rm -rf /tmp/k8s-images" >/dev/null || return
}

remove_docker_images()
{
    log_info "removing docker images ..."

    [[ "$REMOVE_IMAGES_BOOL" = "True" ]] || return 0

    local ips="$1"
    [[ -z "$ips" ]] && return

    cat >/tmp/rm-docker-image <<-EOF
#!/bin/bash

docker_images=\$(docker images)

ret=0
while read -r line; do
    image_id=\$(echo \$line | grep -e "quay.io" -e "gcr.io" | awk '{print \$3}')
    if [[ \$image_id ]]; then
        docker rmi --force \$image_id || ret=1
    fi
done <<< "\$docker_images"

exit \$ret

EOF
    chmod 755 /tmp/rm-docker-image || return

    local ips_num=$(echo $ips | wc -w)
    $PSCP -H "$ips" -p $ips_num -r  /tmp/rm-docker-image /tmp/ || {
        log_error "failed to scp rm-docker-image script to remote"
        return 1
    }

    for ip in $ips; do
        $SSH $ip "/tmp/rm-docker-image" || log_warn "failed to remove all images in $ip"
    done
}


# validate pods are under running status, timeout is 5 mins
# 
# run `kubectl get pods -o wide -n kube-system` output:
# ...
# kube-dns-86f4d74b45-gmdn4                       3/3       Running   0          3d        180.20.128.1     k8s-master3.novalocal
# kube-dns-86f4d74b45-qjkz6                       3/3       Running   0          3d        180.20.154.65    k8s-master2.novalocal
# kube-proxy-lzztt                                1/1       Running   0          3d        192.168.60.12    k8s-master2.novalocal
# kube-proxy-thrr7                                1/1       Running   0          3d        192.168.60.13    k8s-master3.novalocal
# ...
#
# due to kube-dns not use HostIP, need to use hostname to match/filter the specified pod
#
validate_pod_state()
{
    log_info "waiting pods to be running (timeout is 5 mins) ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    local k8s_pods="$2"
    [[ -z "$ips" ]] && return


    local hostname_info
    local hostnames_info
    for ip in $ips; do
        hostname_info=$(get_hostname_by_ip $ip)
        hostnames_info="$hostnames_info $hostname_info"
    done

    local i=1
    local loops=30
    local ret
    local status
    local pods_info
    while (( $loops > $i)); do
        ret=0
        pods_info=$(kubectl get pods -o wide -n kube-system 2>/dev/null)
        for hostname_info in $hostnames_info; do
            for k8s_pod in $k8s_pods; do
                status=$(echo "$pods_info" | grep $k8s_pod | grep $hostname_info | awk '{print $3}')
                [[ "$status" = "Running" ]] || {
                    ret=1
                    break
                 }
            done
            [[ "$ret" = "1" ]] && break
        done

        if [[ "$ret" = "0" ]]; then
            return 0
        else
            echo "waiting $(( 10 * $i)) seconds ..."
            i=$((i + 1))
            sleep 10
        fi
    done

    log_error "$k8s_pods pods are not running, please check it"
    return 1
}

single_init_master()
{
    log_info "init master ..."

    local kubeadm_init_file="$K8S_SRC/config/k8s/kubeadm-init.yaml"
    check_files_exist "$kubeadm_init_file" || return

    # udpate yaml file's kubernetes_version,apiserver_advertise_address and so on
    local temp_kubeadm_init_file="/tmp/kubeadm-init.yaml"
    sed -e "s#\$kubernetes_version#$KUBERNETES_VERSION#" \
        -e "s#\$apiserver_advertise_address#$APISERVER_ADVERTISE_ADDRESS#" \
        -e "s#\$ip#$K8S_IP_MASTER1#" \
        -e "s#\$etcd_data_dir#$ETCD_DATA_DIR#" \
        -e "s#\$pod_network_cidr#$POD_NETWORK_CIDR#" \
        -e "s#\$service_cidr#$SERVICE_CIDR#" \
        -e "s#\$hostname#$(hostname)#" \
        $kubeadm_init_file > $temp_kubeadm_init_file || return

    kubeadm init --config=$temp_kubeadm_init_file  || {
        log_error "failed to initialize master node"
        return 1
    }

    mkdir -p /root/.kube || return
    cp -a /etc/kubernetes/admin.conf $HOME/.kube/config || return

    validate_pod_state "$K8S_IP_MASTER1" "kube-apiserver kube-scheduler kube-controller-manager" || return
}

ha_init_master()
{
    log_info "init master ..."

    local kubeadm_init_file="$K8S_SRC/config/k8s/ha_kubeadm-init.yaml"
    check_files_exist "$kubeadm_init_file" || return

    local ip_master1="$K8S_IP_MASTER1"
    local hostname_master1=$(get_hostname_by_ip $ip_master1)

    local ip_master2="$K8S_IP_MASTER2"
    local hostname_master2=$(get_hostname_by_ip $ip_master2)

    local ip_master3="$K8S_IP_MASTER3"
    local hostname_master3=$(get_hostname_by_ip $ip_master3)

    # udpate yaml file's kubernetes_version,apiserver_advertise_address and so on
    local temp_kubeadm_init_file="/tmp/kubeadm-init.yaml"
    sed -e "s#\$kubernetes_version#$KUBERNETES_VERSION#" \
        -e "s#\$keepalived_virtual_ip#$KEEPALIVED_VIRTUAL_IP#" \
        -e "s#\$ip_master1#$ip_master1#" \
        -e "s#\$ip_master2#$ip_master2#" \
        -e "s#\$ip_master3#$ip_master3#" \
        -e "s#\$hostname_master1#$hostname_master1#" \
        -e "s#\$hostname_master2#$hostname_master2#" \
        -e "s#\$hostname_master3#$hostname_master3#" \
        -e "s#\$etcd_data_dir#$ETCD_DATA_DIR#" \
        -e "s#\$pod_network_cidr#$POD_NETWORK_CIDR#" \
        -e "s#\$service_cidr#$SERVICE_CIDR#" \
        $kubeadm_init_file > $temp_kubeadm_init_file || return

    kubeadm init --config=$temp_kubeadm_init_file  || {
        log_error "failed to initialize master node"
        return 1
    }

    mkdir -p /root/.kube || return
    cp -a /etc/kubernetes/admin.conf /root/.kube/config || return

    validate_pod_state "$K8S_IP_MASTER1" "kube-apiserver kube-scheduler kube-controller-manager" || return
}

ha_join_master()
{
    log_info "join master ..."

    local cert_dir="/etc/kubernetes/pki"
    local kubeadm_init_file="/tmp/kubeadm-init.yaml"

    for ip in $K8S_IP_MASTER2 $K8S_IP_MASTER3; do

        $SCP -r $cert_dir/ca.* $cert_dir/sa.*  $ip:$cert_dir/ || return
        $SCP $kubeadm_init_file  $ip:$kubeadm_init_file || return

        $SSH $ip "kubeadm init --config=$kubeadm_init_file" || {
            log_error "failed to join master in $ip"
            return 1
        }

        $SSH $ip "mkdir -p /root/.kube && cp -a /etc/kubernetes/admin.conf /root/.kube/config" || return
        validate_pod_state "$ip" "kube-apiserver kube-scheduler kube-controller-manager" || return
    done
}

ha_scale_pods()
{
    log_info "scaling calico-kube-controllers and kube-dns ..."

    # to maintain the full HA ability
    kubectl scale --replicas=3 -n kube-system deployment/calico-kube-controllers || {
        log_error "failed to scale calico-kube-controllers"
        return 1
    }
    validate_pod_state "$K8S_IP_MASTERS" "calico-kube-controllers" || return

    kubectl scale --replicas=3 -n kube-system deployment/kube-dns || {
        log_error "failed to scale kube-dns"
        return 1
    }
    validate_pod_state "$K8S_IP_MASTERS" "kube-dns" || return
}

make_master_schedulable()
{
    [[ "$MASTER_SCHEDULABLE_BOOL" = "False" ]] && return 0

    kubectl taint nodes --all node-role.kubernetes.io/master- || {
        log_warn "failed to make master schedulable"
        return 0
    }
}

remove_master_nodes()
{
    log_info "removing master nodes ..."

    for ip in $K8S_IP_MASTER2 $K8S_IP_MASTER3; do
        local node_hostname
        node_hostname=$(get_hostname_by_ip $ip)
        kubectl drain $node_hostname --delete-local-data --force --ignore-daemonsets || log_warn "failed to drain $node_hostname"
        kubectl delete node $node_hostname || log_warn "failed to delete $node_hostname"
        $SSH $ip "kubeadm reset" || log_warn "failed to run kubeadm reset in $node_hostname"
    done

    kubectl drain $(hostname) --delete-local-data --force --ignore-daemonsets || log_warn "failed to drain $(hostname)"
    kubectl delete node $(hostname) || log_warn "failed to delete $(hostname)"
    kubeadm reset || log_warn "failed to run kubeadm reset in $(hostname)"
}

init_k8s_network()
{
    log_info "initialize k8s network ..."

    local calico_config_file="$K8S_SRC/config/calico/calico.yaml"
    local rbac_config_file="$K8S_SRC/config/calico/rbac.yaml"
    check_files_exist $calico_config_file $rbac_config_file || return

    local etcd_key_file="/etc/kubernetes/pki/etcd/client-key.pem"
    local etcd_cert_file="/etc/kubernetes/pki/etcd/client.pem"
    local etcd_ca_file="/etc/kubernetes/pki/etcd/ca.pem"

    local etcd_endpoints
    local etcd_key_base64
    local etcd_cert_base64
    local etcd_ca_base64

    for ip in $K8S_IP_MASTERS; do
        if [[ $etcd_endpoints ]]; then
            etcd_endpoints="$etcd_endpoints,https://$ip:2379"
        else
            etcd_endpoints="https://$ip:2379"
        fi
   done

   etcd_key_base64=$(base64 -w 0 $etcd_key_file)
   etcd_cert_base64=$(base64 -w 0 $etcd_cert_file)
   etcd_ca_base64=$(base64 -w 0 $etcd_ca_file)

    # udpate etcd.service file's hostname,ip,data_dir info
    local temp_calico_config_file="/tmp/calico.yaml"
    sed -e "s#\$calico_reachable_ip#$CALICO_REACHABLE_IP#" \
        -e "s#\$pod_network_cidr#$POD_NETWORK_CIDR#" \
        -e "s#\$etcd_endpoints#$etcd_endpoints#" \
        -e "s#\$etcd_key_base64#$etcd_key_base64#" \
        -e "s#\$etcd_cert_base64#$etcd_cert_base64#" \
        -e "s#\$etcd_ca_base64#$etcd_ca_base64#" \
        $calico_config_file > $temp_calico_config_file || return


    kubectl apply -f $rbac_config_file >/dev/null || {
        log_error "failed to init rbac"
        return 1
    }

    kubectl apply -f $temp_calico_config_file >/dev/null || {
        log_error "failed to init calico"
        return 1
    }

    validate_pod_state "$K8S_IP_MASTER1" "calico-kube-controllers calico-node kube-dns" || return
}

remove_k8s_network()
{
    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)
    $PSSH -H "$ips" -p $ips_num "rm -rf /var/run/calico /var/lib/calico /opt/cni/bin /etc/cin/net.d" || return
}

ha_update_apiserver_port()
{
    log_info "updating apiserver port ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    if [[ "$ACTION" = "install" ]]; then

        local kube_proxy_yaml="/tmp/kube-proxy-cm.yaml"
        kubectl get configmap -n kube-system kube-proxy -o yaml > $kube_proxy_yaml || return

        sed -i "s#server:.*#server: https://$KEEPALIVED_VIRTUAL_IP:$NGINX_LISTEN_PORT#g" $kube_proxy_yaml || return
        kubectl apply -f $kube_proxy_yaml --force || {
            log_error "failed to apply kube proxy yaml"
            return 1
        }

        kubectl delete pod -n kube-system -l k8s-app=kube-proxy || {
            log_error "failed to remove kube proxy pods"
            return 1
        }
    fi

    for ip in $ips; do
        $SSH $ip "sed -i \"s#server:.*#server: https://$KEEPALIVED_VIRTUAL_IP:$NGINX_LISTEN_PORT#\" /etc/kubernetes/*.conf" || return
        $SSH $ip "systemctl restart kubelet" || {
            log_error "failed to restart kubelet in $node_info"
            return 1
        }
    done

    validate_pod_state "$ips" "calico-node kube-proxy" || return
}

add_worker_nodes()
{
    log_info "adding worker nodes ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    local ips_num=$(echo $ips | wc -w)
    local join_cluster_cmd=$(kubeadm token create --print-join-command)

    for ip in $ips; do
        $SSH $ip "$join_cluster_cmd" || {
            log_error "failed to add worker node: $ip"
            return 1
        }
    done

    validate_pod_state "$ips" "calico-node kube-proxy" || return
}

remove_worker_nodes()
{
    log_info "removing worker nodes ..."

    local ips="$1"
    [[ -z "$ips" ]] && return

    local node_hostname
    for ip in $ips; do
        node_hostname=$(get_hostname_by_ip $ip)
        kubectl drain $node_hostname --delete-local-data --force --ignore-daemonsets || log_warn "failed to drain $node_hostname"
        kubectl delete node $node_hostname || log_warn "failed to delete node $node_hostname"
        $SSH $ip "kubeadm reset" || log_warn "failed to run kubeadm reset in $node_hostname"
    done
}

update_installed_ip()
{
    log_info "updating installed ip ..."

    case $ACTION in
        install)
            echo > $K8S_SRC/.installed_ip
            for ip in $K8S_IP_MASTERS; do
                echo "MASTER: $ip" >> $K8S_SRC/.installed_ip
            done

            for ip in $K8S_IP_WORKERS; do
                echo "WORKER: $ip" >> $K8S_SRC/.installed_ip
            done
            ;;
        add)
            for ip in $K8S_IP_WORKERS; do
                echo "WORKER: $ip" >> $K8S_SRC/.installed_ip
            done
            ;;
        remove)
            for ip in $K8S_IP_WORKERS; do
                sed -i "/WORKER: $ip/d" $K8S_SRC/.installed_ip || {
                    log_error "failed to remove ip: $ip in $K8S_SRC/.installed_ip"
                    return 1
                }
            done
            ;;
        uninstall)
            echo > $K8S_SRC/.installed_ip
            ;;
    esac
}

ACTION="$1"
case $ACTION in
    install | uninstall)
        :
        ;;
    add)
        ADD_IP_WORKER="$2"
        if [[ -z $ADD_IP_WORKER ]]; then
            log_error "must be specify one worker node's IP address"
            usage
        fi
        ;;
    remove)
        REMOVE_IP_WORKER="$2"
        if [[ -z $REMOVE_IP_WORKER ]]; then
            log_error "must be specify one worker node's IP address"
            usage
        fi
        ;;
    *)
        usage
    ;;
esac


[[ "$(id -u)" = "0" ]] || {
    log_error "must be run as root"
    exit 1
}

K8S_SRC=$(dirname $(readlink -e -v $0))
mkdir -p ${K8S_SRC}/log || exit

log_file=${K8S_SRC}/log/${ACTION}_log-$(date +%F-%T)
# redirect stdout and stderr to $log_file and print
exec > >(tee -ia $log_file)
exec 2> >(tee -ia $log_file >&2)

check_command nmap || exit
check_command timeout || exit
check_command getenforce || exit

check_command ssh || exit
SSH="ssh"

check_command scp || exit
SCP="scp"

check_command pssh &>/dev/null ||
{
    pssh_rpm=($K8S_SRC/yum/pssh-*.rpm)
    [[ "$pssh_rpm" ]] && rpm -i $pssh_rpm >/dev/null
}

check_command pssh || exit
PSSH="pssh -i --timeout 0"

if check_command pscp &>/dev/null; then
PSCP="pscp --timeout 0"
else
    if check_command pscp.pssh &>/dev/null; then
        PSCP="pscp.pssh --timeout 0"
    else
        log_error "cannot find pscp command"
        exit 1
    fi
fi


parse_deploy_config || exit
check_deploy_config || exit

if [[ $ACTION = "install" || "$ACTION" = "uninstall" ]]; then
    check_nodes_status "$K8S_IP_MASTERS $K8S_IP_WORKERS" || exit
else
    check_nodes_status "$K8S_IP_WORKERS" || exit
fi


case "$ACTION" in
    install)
        disable_swap "$K8S_IP_MASTERS $K8S_IP_WORKERS" || exit
        enable_bridge_nf_call "$K8S_IP_MASTERS $K8S_IP_WORKERS" || exit
        install_k8s_pkg "$K8S_IP_MASTERS $K8S_IP_WORKERS" || exit
        update_k8s_config "$K8S_IP_MASTERS $K8S_IP_WORKERS" || exit

        if [[ $HA_DEPLOYMENT = "True" ]]; then
            generate_etcd_cert || exit
            ha_config_etcd || exit
            ha_config_keepalived  || exit
            ha_config_nginx || exit
            load_master_images "$K8S_IP_MASTERS" || exit
            load_worker_images "$K8S_IP_WORKERS" || exit
            ha_init_master || exit
            init_k8s_network || exit
            ha_join_master || exit
            ha_scale_pods || exit
            make_master_schedulable || exit
            add_worker_nodes "$K8S_IP_WORKERS" || exit
            ha_update_apiserver_port "$K8S_IP_MASTERS $K8S_IP_WORKERS" || exit
            update_installed_ip || exit
        else
            generate_etcd_cert || exit
            single_config_etcd || exit
            load_master_images "$K8S_IP_MASTERS" || exit
            load_worker_images "$K8S_IP_WORKERS" || exit
            single_init_master  || exit
            init_k8s_network || exit
            make_master_schedulable || exit
            add_worker_nodes "$K8S_IP_WORKERS" || exit
            update_installed_ip || exit
        fi
        ;;
    add)
        disable_swap "$K8S_IP_WORKERS" || exit
        enable_bridge_nf_call "$K8S_IP_WORKERS" || exit
        install_k8s_pkg "$K8S_IP_WORKERS" || exit
        update_k8s_config "$K8S_IP_WORKERS" || exit
        load_worker_images "$K8S_IP_WORKERS" || exit
        add_worker_nodes "$K8S_IP_WORKERS"|| exit

        if [[ $HA_DEPLOYMENT = "True" ]]; then
            ha_update_apiserver_port "$K8S_IP_WORKERS" || exit
        fi
        update_installed_ip || exit
        ;;

    remove)
        remove_worker_nodes "$K8S_IP_WORKERS"
        remove_k8s_pkg "$K8S_IP_WORKERS"
        remove_docker_images "$K8S_IP_WORKERS"
        restore_swap "$K8S_IP_WORKERS"
        update_installed_ip
        ;;

    uninstall)
        remove_worker_nodes "$K8S_IP_WORKERS"
        remove_master_nodes
        remove_k8s_pkg "$K8S_IP_MASTERS $K8S_IP_WORKERS"
        remove_etcd "$K8S_IP_MASTERS"
        remove_k8s_network "$K8S_IP_MASTERS $K8S_IP_WORKERS"
        remove_docker_images "$K8S_IP_MASTERS $K8S_IP_WORKERS"
        ha_remove_nginx
        ha_remove_keepalived
        restore_swap "$K8S_IP_MASTERS $K8S_IP_WORKERS"
        update_installed_ip
        ;;
esac

log_info "succeed in run \"$ACTION\" operation"
