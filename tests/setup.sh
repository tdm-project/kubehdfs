#!/usr/bin/env bash

# Exit on error. Append "|| true" if you expect an error.
set -o errexit
# Exit on error inside any functions or subshells.
set -o errtrace
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
set -o nounset
# Catch an error in command pipes. e.g. mysqldump fails (but gzip succeeds)
# in `mysqldump |gzip`
set -o pipefail
if [[ "${DEBUG:-}" = "true" ]]; then
# Turn on traces, useful while debugging but commented out by default
  set -o xtrace
fi

_MY_SCRIPT="${BASH_SOURCE[0]}"
_MY_DIR=$(cd "$(dirname "$_MY_SCRIPT")" && pwd)

export MINIKUBE_WANTUPDATENOTIFICATION=false
export MINIKUBE_WANTREPORTERRORPROMPT=false
export CHANGE_MINIKUBE_NONE_USER=true

cd $_MY_DIR

source lib/_k8s.sh

rm -rf tmp
mkdir -p bin tmp
echo Installing minikube
sudo bash -c 'curl -Lo /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && chmod +x /usr/local/bin/minikube'

if [[ "${USE_MINIKUBE_DRIVER_NONE:-}" = "true" ]]; then
  # Run minikube with none driver.
  # See https://blog.travis-ci.com/2017-10-26-running-kubernetes-on-travis-ci-with-minikube
  echo nsenter: $(command -v nsenter)
  _VM_DRIVER="--vm-driver=none"
fi

_MINIKUBE="minikube"
if [[ "${USE_SUDO_MINIKUBE:-}" = "true" ]]; then
  _MINIKUBE="sudo minikube"
fi

$_MINIKUBE start ${_VM_DRIVER:-}
# Fix the kubectl context, as it's often stale.
$_MINIKUBE update-context
echo Minikube disks:
if [[ "${USE_MINIKUBE_DRIVER_NONE:-}" = "true" ]]; then
  # minikube does not support ssh for --vm-driver=none
  df
else
  $_MINIKUBE ssh df
fi

# Wait for Kubernetes to be up and ready.
k8s_single_node_ready

echo Minikube addons:
$_MINIKUBE addons list
kubectl get storageclass
echo Showing kube-system pods
kubectl get -n kube-system pods

(k8s_single_pod_ready -n kube-system -l component=kube-addon-manager) ||
  (_ADDON=$(kubectl get pod -n kube-system -l component=kube-addon-manager
      --no-headers -o name| cut -d/ -f2);
   echo Addon-manager describe:;
   kubectl describe pod -n kube-system $_ADDON;
   echo Addon-manager log:;
   kubectl logs -n kube-system $_ADDON;
   exit 1)
k8s_all_pods_ready 2 -n kube-system -l k8s-app=kube-dns
k8s_single_pod_ready -n kube-system storage-provisioner

helm init
k8s_single_pod_ready -n kube-system -l name=tiller
