curl -sfL https://get.rke2.io --output install.sh && chmod +x install.sh && \

sudo mkdir -p /etc/rancher/rke2

cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
node-name:
  - "rancher"
token: my-shared-secret
EOF

sudo INSTALL_RKE2_CHANNEL=v1.26.12+rke2r1 ./install.sh && \

export PATH=$PATH:/opt/rke2/bin && \

sudo systemctl enable rke2-server --now && \

mkdir -p $HOME/.kube && sudo cp /etc/rancher/rke2/rke2.yaml $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config && sudo cp /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/ && \

kubectl get po -A && \

sleep 180 && \

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && \
helm repo add rancher-prime https://charts.rancher.com/server-charts/prime && \
kubectl create ns cattle-system && \
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.crds.yaml && \

sleep 60 && \
helm repo add jetstack https://charts.jetstack.io && \
helm repo update && \
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.0 && \
kubectl get pods -n cert-manager && \

sleep 180

helm install rancher rancher-prime/rancher \
  --namespace cattle-system \
  --set hostname=172.20.0.157.nip.io \
  --set bootstrapPassword=rancheradmin \
  --set global.cattle.psp.enabled=false \
  --set replicas=1 \
  --version 2.8.2 && \

sleep 60
watch -n 1 kubectl -n cattle-system get po