#!/bin/bash

# 設定 Debug 模式
## 預設將執行中的指令及其參數重新導向到 /tmp/prepare_message.log 檔案中
[[ -z "${Command_log_file}" ]] && Command_log_file="/tmp/prepare_message.log"
[[ -f "${Command_log_file}" ]] && sudo rm "${Command_log_file}"
exec {BASH_XTRACEFD}>>"${Command_log_file}"
set -x

## 預設確保命令執行後的輸出重定向到 /tmp/prepare_output_message.log 檔案中
[[ -z "${Command_Output_log_file}" ]] && Command_Output_log_file="/tmp/prepare_output_message.log"
[[ -f "${Command_Output_log_file}" ]] && sudo rm "${Command_Output_log_file}"

usage() {
  cat <<EOF
Usage:
  ENV_VAR=... $(basename "${BASH_SOURCE[0]}") [options]

Available options:

all        一次準備 Harbor、RKE2、Rancher 的全離線安裝包
harbor     只準備 Harbor 的全離線安裝包
rke2       只準備 RKE2 的全離線安裝包
rancher    只準備 Rancher 的全離線安裝包
neuvector  只準備 Neuvector 的全離線安裝包
k3s        只準備 K3S 的全離線安裝包

Environment variables:

   - Harbor_Version
     定義 Harbor 的版本
     預設是 'v2.10.0'。

   - Docker_Compose_Version
     定義 docker-compose 的版本
     預設是 'v2.24.7'。

   - RKE2_Version
     定義 RKE2 的版本
     預設是 'v1.27.11'。

   - Rancher_Version
     定義 Rancher 的版本
     預設是 'v2.8.2'。

   - Helm_Version
     定義 Helm 的版本
     預設是 'v3.14.2'。

   - Cert_Manager_Version
     定義 Cert-manager 的版本
     預設是 'v1.11.0'。

   - K3S_Version
     定義 K3S 的版本
     預設是 'v1.27.11'。

   - Neuvector_Version
     定義 Neuvector 的版本
     預設是 '5.3.0'。

   - Private_Registry_Name
     定義企業內部私有 Image Registry 的名稱
     預設是 'harbor.example.com'。

   - Command_log_file
     將命令執行後的輸出重新導向到 /tmp/prepare_message.log
     預設是 '/tmp/prepare_message.log'。

   - Command_Output_log_file
     將命令執行後的輸出重新導向到 /tmp/prepare_output_message.log
     預設是 '/tmp/prepare_output_message.log'。

Example:
  ## 一次準備 Harbor、RKE2、Rancher 的全離線安裝包，並且指定安裝 Harbor 特定版本
  Harbor_Version=v2.7.0 ./prepare.sh all

  ## 只準備 Rancher 的全離線安裝包，並且指定安裝 Rancher 特定版本
  Rancher_Version=v2.7.9 ./prepare.sh rancher
EOF
  exit
}

[[ "$#" -eq "0" ]] && usage

# Confirm the environment required for program execution and define predefined variables
setup_env() {
  # check internet connection
  if ! nc -vz google.com 443 &> /dev/null; then
    echo "internet connection is offline" && exit 1
  fi

  # check Command is installed
  for command in wget curl docker
  do
    if ! which $command &> /dev/null; then
      echo "${Command} command not found!" && exit 1
    fi
  done

  # make sure the version of the Harbor is defined
  if [[ -z "${Harbor_Version}" ]]; then
    Harbor_Version="v2.10.0"
  fi

  # make sure the version of the Docker-compose is defined
  if [[ -z "${Docker_Compose_Version}" ]]; then
    Docker_Compose_Version="v2.24.7"
  fi

  # make sure the version of the RKE2 is defined
  if [[ -z "${RKE2_Version}" ]]; then
    RKE2_Version="v1.27.11"
  fi

  # make sure the version of the Rancher is defined
  if [[ -z "${Rancher_Version}" ]]; then
    Rancher_Version="v2.8.2"
  fi

  # make sure the version of the Helm is defined
  if [[ -z "${Helm_Version}" ]]; then
    Helm_Version="v3.14.2"
  fi

  # make sure the version of the Cert-Manager is defined
  if [[ -z "${Cert_Manager_Version}" ]]; then
    Cert_Manager_Version="v1.11.0"
  fi

  # make sure the version of the K3S is defined
  if [[ -z "${K3S_Version}" ]]; then
    K3S_Version="v1.27.11"
  fi

  # make sure the version of the Neuvector is defined
  if [[ -z "${Neuvector_Version}" ]]; then
    Neuvector_Version="5.3.0"
  fi

  # make sure the name of the Private Images Registry is defined
  if [[ -z "${Private_Registry_Name}" ]]; then
    Private_Registry_Name="harbor.example.com"
  fi
}

# 建立工作目錄
create_working_directory() {
  setup_env
  mkdir -p ~/work/{harbor/"${Harbor_Version}",rke2/"${RKE2_Version}",rancher/"${Rancher_Version}",k3s/"${K3S_Version}",neuvector/"${Neuvector_Version}",compressed_files}
}

# 準備 Harbor 全離線安裝包
prepare_harbor() {
  setup_env

  # 切換工作目錄
  cd ~/work/harbor/"${Harbor_Version}"

  # 下載 Harbor 壓縮檔
  wget https://github.com/goharbor/harbor/releases/download/"${Harbor_Version}"/harbor-offline-installer-"${Harbor_Version}".tgz &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download harbor-offline-installer-"${Harbor_Version}".tgz failed" && exit 1

  # 下載 Docker Compose 套件
  wget https://github.com/docker/compose/releases/download/"${Docker_Compose_Version}"/docker-compose-linux-x86_64 &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download docker-compose-linux-x86_64 "${Docker_Compose_Version}" failed" && exit 1

  # 將以上離線安裝 Harbor 所需之套件壓縮成一個檔案
  cd ../..; tar -czvf compressed_files/harbor-offline-"${Harbor_Version}".tar.gz harbor/"${Harbor_Version}" &>> "${Command_Output_log_file}"
  if [[ "$?" != "0" ]]; then
    echo "Preparing harbor full Air Gap installer failed" && exit 1
  else
    echo "Prepare Harbor "${Harbor_Version}" OK."
  fi
}

# 準備 RKE2 全離線安裝包
prepare_rke2() {
  setup_env
  # 切換工作目錄
  cd ~/work/rke2/"${RKE2_Version}"

  # 下載離線安裝 RKE2 所需 Image 之壓縮檔
  curl -s -OL https://github.com/rancher/rke2/releases/download/"${RKE2_Version}"%2Brke2r1/rke2-images.linux-amd64.tar.zst &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download rke2-images.linux-amd64.tar.zst "${RKE2_Version}" failed" && exit 1

  curl -s -OL https://github.com/rancher/rke2/releases/download/"${RKE2_Version}"%2Brke2r1/rke2.linux-amd64.tar.gz &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download rke2.linux-amd64.tar.gz "${RKE2_Version}" failed" && exit 1

  curl -s -OL https://github.com/rancher/rke2/releases/download/"${RKE2_Version}"%2Brke2r1/sha256sum-amd64.txt &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download sha256sum-amd64.txt "${RKE2_Version}" failed" && exit 1

  # 下載官網提供的離線安裝 RKE2 所需之安裝腳本，並賦予它執行權限
  curl -sfL https://get.rke2.io --output install.sh && chmod +x install.sh &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download rke2 install.sh failed" && exit 1

  # 將以上離線安裝 RKE2 所需之檔案，壓縮成一個檔案
  cd ../..; tar -czvf compressed_files/rke2-offline-"${RKE2_Version}".tar.gz rke2/"${RKE2_Version}" &>> "${Command_Output_log_file}"
  if [[ "$?" != "0" ]]; then
    echo "Preparing RKE2 Air Gap installer failed" && exit 1
  else
    echo "Prepare RKE2 "${RKE2_Version}" OK."
  fi
}

# 準備 Rancher Prime 全離線安裝包
prepare_rancher() {

  setup_env
  # 切換工作目錄
  cd ~/work/rancher/"${Rancher_Version}"

  # 安裝 helm
  curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Install helm failed" && exit 1

  # 新增並刷新 Rancher Prime 的 Helm Chart Repository
  helm repo add rancher-prime https://charts.rancher.com/server-charts/prime &>> "${Command_Output_log_file}" && \
  helm repo update &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "helm repo add or update rancher-prime failed" && exit 1

  # 下載 Rancher chart
  helm fetch rancher-prime/rancher --version="${Rancher_Version}" &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "helm fetch rancher failed" && exit 1

  # 新增和刷新 cert-manager repo
  helm repo add jetstack https://charts.jetstack.io &>> "${Command_Output_log_file}" && \
  helm repo update &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "helm repo add or update cert-manager failed" && exit 1

  # 下載 cert-manager chart
  helm fetch jetstack/cert-manager --version "${Cert_Manager_Version}" &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "helm fetch Cert_Manager failed" && exit 1

  # 下載 cert-manager 要求的 CRD
  curl -L -o cert-manager-crd.yaml https://github.com/cert-manager/cert-manager/releases/download/"${Cert_Manager_Version}"/cert-manager.crds.yaml &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download Cert_Manager CRD failed" && exit 1

  # 處理 cert-manager 的 Container Images
  for i in $(helm template cert-manager-*.tgz | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g')
  do
    # 下載 cert-manager 的 Container Images
    sudo docker pull "$i" &>> "${Command_Output_log_file}"
    [[ "$?" != "0" ]] && echo "Pull quay.io/jetstack/$i Container images failed" && exit 1

    # 修改 cert-manager 的所有 Container Images Tag
    sudo docker tag "${i}" "${Private_Registry_Name}"/rancher/"${i##*/}" &>> "${Command_Output_log_file}"
    [[ "$?" != "0" ]] && echo "tag ${Private_Registry_Name}/rancher/${i##*/} Container images failed" && exit 1
  done

  # 將 cert-manager 的所有 Container Images 打包成 .tar.gz 壓縮檔
  sudo docker save $(helm template cert-manager-*.tgz | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g' | sed "s|quay.io/jetstack|${Private_Registry_Name}/rancher|g") | gzip --stdout > ~/work/rancher/cert-manager-image-"${Cert_Manager_Version}".tar.gz &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Docker save Cert-manager ${Cert_Manager_Version} images failed" && exit 1

  # 下載 Helm 壓縮檔
  wget https://get.helm.sh/helm-"${Helm_Version}"-linux-amd64.tar.gz -O ~/work/rancher/helm-"${Helm_Version}"-linux-amd64.tar.gz &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download helm ${Helm_Version} failed"

  # 下載 Rancher Images List 文字檔及蒐集 Image 所需的 Shell Script
  for x in rancher-images.txt rancher-load-images.sh rancher-save-images.sh
  do
    wget https://github.com/rancher/rancher/releases/download/"${Rancher_Version}"/"${x}" &>> "${Command_Output_log_file}"
    [[ "$?" != "0" ]] && echo "Download ${x} failed" && exit 1
  done

  # 對 Image List 進行排序和唯一化，以消除來源之間的任何重疊
  sort -u rancher-images.txt -o rancher-images.txt &>> "${Command_Output_log_file}"

  [[ "$?" == "0" ]] && echo "Start pulling and saving rancher ${Rancher_Version} images in the background..."
  # 下載離線安裝 Rancher 所需的所有 Container Images 並打包成 rancher-images.tar.gz
  while read image
  do
    if ! sudo docker pull registry.rancher.com/"${image}" &>> "${Command_Output_log_file}"; then
      echo pull "$image" failed && exit 1
    fi
  done <<< $(cat rancher-images.txt)

  rancher_all_image=$(cat rancher-images.txt | tr '\n' ' ')
  for n in $rancher_all_image
  do
    if ! sudo docker images "$n" | grep -q "${n%:*}"; then
      if ! sudo docker pull registry.rancher.com/"$n" &>> "${Command_Output_log_file}"; then
        echo pull "$n" failed twice && exit 1
      fi
    fi
  done

  sudo docker save $rancher_all_image &>> "${Command_Output_log_file}" | gzip --stdout > rancher-"${Rancher_Version}"-image.tar.gz &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]]  && echo "Docker Save rancher ${Rancher_Version} images failed" && exit 1

  cd ../..; tar -czf ../compressed_files/rancher-offline-"${Rancher_Version}".tar.gz rancher/"${Rancher_Version}" &>> "${Command_Output_log_file}"
  if [[ "$?" != "0" ]]; then
    echo "Preparing Rancher "${Rancher_Version}" Air Gap installer failed" && exit 1
  else
    echo "Prepare Rancher "${Rancher_Version}" OK."
  fi

  # 賦予兩個 shell script 可以執行的權限
  # chmod +x rancher-*-images.sh
  # 下載離線安裝 Rancher 所需的所有 Container Images 並打包成 rancher-images.tar.gz
  # sudo bash -x rancher-save-images.sh \
  #   --image-list ./rancher-images.txt \
  #   --source-registry "registry.rancher.com" \
  #   --images ~/work/rancher/rancher-images.tar.gz \
  #   &>> /tmp/rancher-save-images.log &
  #   [[ "$?" == "0" ]] && echo "Start pulling and saving rancher images in the background..."
}

prepare_k3s() {
  setup_env

  # 切換工作目錄
  cd ~/work/k3s/"K3S_Version"

  curl -# -OL https://github.com/k3s-io/k3s/releases/download/"${K3S_Version}"%2Bk3s1/k3s-airgap-images-amd64.tar &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download k3s-airgap-images-amd64.tar ${K3S_Version} failed" && exit 1

  curl -# -OL https://github.com/k3s-io/k3s/releases/download/"{K3S_Version}"%2Bk3s1/k3s &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download k3s Binary File ${K3S_Version} failed" && exit 1

  curl -sfL https://get.k3s.io/ --output install.sh && chmod +x install.sh &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Download k3s Official Installation Script failed" && exit 1

  cd ../..; tar -czf compressed_files/k3s-offline-"${K3S_Version}".tar.gz k3s/"${K3S_Version}"
  if [[ "$?" != "0" ]]; then
    echo "Preparing K3S ${K3S_Version} Air Gap installer failed" && exit 1
  else
    echo "Prepare K3S "${K3S_Version}" OK."
  fi
}

prepare_neuvector() {
  setup_env

  # 切換工作目錄
  cd ~/work/neuvector/"${Neuvector_Version}"

  # install helm
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Install helm failed" && exit 1

  # add repo
  helm repo add neuvector https://neuvector.github.io/neuvector-helm/ &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Add Neuvector Helm Repo failed" && exit 1

  # update local chart
  helm repo update &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Update Neuvector Helm Repo failed" && exit 1

  # get specify chart version
  Chart_Version=$(helm search repo neuvector/core --versions | grep "${Neuvector_Version}" | head -n 1 | fmt -u | cut -d " " -f 2)

  # pull
  helm pull neuvector/core --version "${Chart_Version}" &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Pull Neuvector ${Neuvector_Version} Helm packages failed" && exit 1

  # create image list
  helm template core-*.tgz | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g' > images-list.txt &>> "${Command_Output_log_file}"

  # get images
  for i in $(cat images-list.txt)
  do
    sudo docker pull $i &>> "${Command_Output_log_file}"
    [[ "$?" != "0" ]] && echo "Pull $i failed" && exit 1
  done

  # save images to tar.gz
  sudo docker save $(cat images-list.txt) | gzip --stdout > neuvector-images-"${Neuvector_Version}".tar.gz &>> "${Command_Output_log_file}"
  [[ "$?" != "0" ]] && echo "Docker save Neuvector images ${Neuvector_Version} failed" && exit 1

  cd ../..; tar -czf compressed_files/neuvector-offline-"${Neuvector_Version}".tar.gz neuvector/"${Neuvector_Version}"
  if [[ "$?" != "0" ]]; then
    echo "Preparing Neuvector Air Gap installer failed" && exit 1
  else
    echo "Prepare RKE2 ${RKE2_Version} OK."
  fi
}

while [[ "$#" -gt "0" ]]
do
  option="$1"
  case $option in
    all)
      create_working_directory 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_harbor 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_rke2 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_rancher 2>&1 | tee -a "${Command_Output_log_file}"
      exit 0
    ;;
    harbor)
      create_working_directory 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_harbor 2>&1 | tee -a "${Command_Output_log_file}"
      shift
    ;;
    rke2)
      create_working_directory 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_rke2 2>&1 | tee -a "${Command_Output_log_file}"
      shift
    ;;
    rancher)
      create_working_directory 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_rancher 2>&1 | tee -a "${Command_Output_log_file}"
      shift
    ;;
    k3s)
      create_working_directory 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_k3s 2>&1 | tee -a "${Command_Output_log_file}"
      shift
    ;;
    neuvector)
      create_working_directory 2>&1 | tee -a "${Command_Output_log_file}"
      prepare_neuvector 2>&1 | tee -a "${Command_Output_log_file}"
      shift
    ;;
    *)
      usage
      exit 1
    ;;
  esac
done
