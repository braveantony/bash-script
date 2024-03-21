#!/bin/bash

if ! which podman &> /dev/null; then
  echo "podman command not found" && exit 1
else
  podman images &> /dev/null
  [[ "$?" != "0" ]] && echo "Run Rootless Podman Failed" && exit 1
fi

usage() {
  cat <<EOF
Descriptions:
  預載 YAML 檔中宣告的所有 Container Images

Usage:
  $(basename "${BASH_SOURCE[0]}") [options]

Available options:
    -f:
        The YAML files that contain the configurations to pull.
    -h:
        show this help text.

Examples:
  # 先 Pull 指定 YAML 檔中定義的所有 Container Images
  ./pre-pull -f deployment.yaml

  # 先 Pull 指定多個 YAML 檔中定義的所有 Container Images
  ./pre-pull -f deployment.yaml -f pod.yaml

  # 先 Pull 指定目錄區的所有 *.yaml 和 *.yml 檔案中的所有 Container Images
  ./pre-pull -f ./
EOF
  exit 0
}

pull_image() {
  if [[ -f "$File" ]]; then
    Container_Images=$( cat "$File" | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g' | sort -u | uniq)
  elif [[ -d "$File" ]]; then
    Files=$(find "$File" -name '*.yaml' -o -name '*.yml' | tr "\n" " ")
    Container_Images=$( cat $Files | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g' | sort -u | uniq)
  fi
  for i in $Container_Images
  do
    podman pull "$i" &> /dev/null
    if [[ "$?" != "0" ]]; then
      echo "Pull ${i} Container Images Filed" && exit 1
    else
      echo "Pull ${i} Container Images ok"
    fi
  done
}

[[ "$#" -eq "0" ]] && usage

while [[ "$#" -gt "0" ]]
do
  option="$1"
  case $option in
    -f)
      File="$2"
      pull_image
      shift
      shift
    ;;
    *)
      usage
    ;;
  esac
done
