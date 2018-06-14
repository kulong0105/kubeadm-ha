#!/bin/bash

curl --silent --max-time 2 --insecure https://localhost:6443/ -o /dev/null || {
    echo "Error: failed to get https://localhost:6443/"
    exit 1
}

if ip addr | grep -q $keepalived_virtual_ip; then
    curl --silent --max-time 2 --insecure https://$keepalived_virtual_ip:6443/ -o /dev/null || {
        echo "Error: failed to get https://$keepalived_virtual_ip:6443/"
        exit 1
    }
fi
