#!/bin/bash

set -x

images=$(sudo docker images -aq)

for i in $images
do
  sudo docker rmi -f "$i" &> /dev/null
  [[ "$?" != "0" ]] && echo clean up "$i" image failed && exit 1
done
