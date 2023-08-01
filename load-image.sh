#!/bin/bash

# ========================================
# Description:
#   load Neuvector Image on each node of OCP cluster.
# Prerequest:
#   prepare neuvector-5.2.0-image.tar.gz on each node of OCP cluster.
# Download neuvector-5.2.0-image.tar.gz Command:
#    wget -q --progress=bar --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate 'https://docs.google.com/uc?export=download&id=12dlIHkbCKFDHonNllP7l1cTdQ9G999dO' -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')&id=12dlIHkbCKFDHonNllP7l1cTdQ9G999dO" -O neuvector-5.2.0-image.tar.gz
# ========================================

# Debug Mode
# set -x

node_name=$(oc get nodes -o=custom-columns=NAME:.metadata.name | sed 1d)

for n in $node_name
do
  cat <<EOF | oc debug node/"$n"
chroot /host
#podman images | grep neuvector
#podman rmi docker.io/neuvector/scanner:latest docker.io/neuvector/updater:latest docker.io/neuvector/manager:5.2.0 docker.io/neuvector/enforcer:5.2.0 docker.io/neuvector/controller:5.2.0
podman load < /home/core/neuvector-5.2.0-image.tar.gz
EOF
done
