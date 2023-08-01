#!/bin/bash

# check Env before installing Neuvector on OCP

## check Taint

echo "Starting Check The Taint Info On a Node"

for i in $(oc get node -o=jsonpath='{.items[*].metadata.name}')
do
  echo
  echo "$i"
  echo
  if [[ -z $(oc get node "$i" -o=jsonpath='{.spec.taints}') ]]; then
    echo "  No Taints on the $i"
  else
    echo "  $(oc get node "$i" -o=jsonpath='{.spec.taints}')"
  fi
done

echo
echo "Note: All taint info must match to schedule Enforcers on nodes"
echo "=================="

## check CRI-O run-time

echo "Starting Check CRI-O run-time"

for i in $(oc get node -o=jsonpath='{.items[*].metadata.name}')
do
  echo
  echo "$i"
  echo
  cat <<EOF | oc debug node/"$i" 2> /dev/null
chroot /host
ps -eaf | grep kubelet | tr ' ' '\n' |  grep -w -- '--container-runtime-endpoint'
EOF
done

echo "=================="

## check defaultNodeSelector

echo "Starting Check defaultNodeSelector"

if [[ -z $(oc get scheduler cluster -o yaml | grep defaultNodeSelector) ]]; then
  echo "  No defaultNodeSelector"
else
  oc get scheduler cluster -o yaml | grep -A10 defaultNodeSelector
fi

echo "=================="
echo "End Check"
