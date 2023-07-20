#!/bin/bash

# Debug mode
# set -x

# test sudo, run as root
if ! command -v sudo &>/dev/null; then
  echo "pls install sudo command: zypper in -y sudo, or you can run as root" && exit 0
fi

# var
line_base_a=$(sudo cat /etc/sudoers | grep -n 'NOPASSWD: ALL')
line_base_b=$(cat /etc/group | grep -nw "^wheel")
user_name=$(id -un)

# check var
if [[ -z "${line_base_a%%:*}" ]] || [[ -z "${line_base_b%%:*}" ]];then
  echo "var has error" && exit 0
fi

# 設定 wheel 群組執行 sudo 命令時免密碼
sudo sed -i "${line_base_a%%:*}s|#||" /etc/sudoers

# 將當前使用者加入 wheel 群組
sudo sed -i "${line_base_b%%:*}s|$|${user_name}|" /etc/group
