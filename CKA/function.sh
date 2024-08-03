#!/bin/bash

set -x

CheckPodStatus() {
  for pod in $@
  do
    kubectl get pod "${pod}" --namespace "${Namespace}" --output json | jq '
      .status | {
        phase, containerStatuses: [.containerStatuses[] | {name, ready}]
      } | .phase'
  done
}

CheckContainersReady() {
  for container in $@
  do
    kubectl get pod "${container}" --namespace "${Namespace}" --output json | jq '
      .status | {
        phase, containerStatuses: .containerStatuses[] | {name, ready}
      } | .containerStatuses.ready'
  done
}

NumberOfContainers() {
  for pod in $@
  do
    kubectl get pod "${pod}" --namespace "${Namespace}" --output json | jq '
     .spec.containers | length'
  done
}

CKA01() {
  Nmaespace='default'
  PodStatus=$(CheckPodStatus kucc8)
  Count=$(NumberOfContainers kucc8)
  ContainerStatus=$(CheckContainersReady kucc8)

  if [[ "${PodStatus//\"/}" != "Running" ]]; then
    echo "kucc8 pod in ${NAMESPACE} is not Running"
  else
    echo "Pass"
  fi

  if [[ "$(echo ${ContainerStatus} | grep -o true | wc -l)" -ne "${Count}" ]]; then
    echo "kucc8 pod in ${NAMESPACE} has NotReady Container"
  else
    echo "Pass"
  fi
}

CKA01
