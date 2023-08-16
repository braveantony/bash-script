#!/bin/bash

# ========================================
# Description:
#   Download Google Drive Files.
# Prerequest:
#   Make sure that the files you want to download on Google drive are public.
# ========================================

# var
Download_URL_Base=$2
Download_URL=$(echo $Download_URL_Base | tr -s "/" "\n" | sed -n 5p)
Output_File_name=$3

# function
## debug mode
Debug() {
  ### output log
  exec {BASH_XTRACEFD}>> /tmp/download_message.log
  set -x
  #set -o pipefail
}

## check vars
check_vars() {
  var_names=("Download_URL_Base" "Download_URL" "Output_File_name")
  for var_name in "${var_names[@]}"; do
      [ -z "${!var_name}" ] && echo "$var_name is unset." && exit 1
  done
  return 0
}

## Print usage
usage() {
  cat <<EOF
Usage:
  $(basename "${BASH_SOURCE[0]}") [options] [shared link] [output file name]

Available options:

-s               Download files under 100 mb
-b               Download files over 100 mb
-h,  --help      Print This help text
EOF
  exit
}

# main program
case "${1-}" in
  -b)
    check_vars
    Debug
    wget --show-progress -q --load-cookies /tmp/cookies.txt "https://docs.google.com/uc?export=download&confirm=$(wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate "https://docs.google.com/uc?export=download&id=$Download_URL" -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')&id=$Download_URL" -O "$Output_File_name" && rm -rf /tmp/cookies.txt
    ;;
  -s)
    check_vars
    Debug
    wget --show-progress -q --no-check-certificate "https://docs.google.com/uc?export=download&id=$Download_URL" -O "$Output_File_name"
    ;;
  -h|*|--help)
    usage
    ;;
esac
