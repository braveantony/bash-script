#!/bin/bash
cd
kubectl cp ~/wulin-gcp/bin/ kube-system/kube-kadm:/home/bigred/wulin -c kadm
echo "copy wulin/bin ok"
kubectl cp ~/wulin-gcp/images/ kube-system/kube-kadm:/home/bigred/wulin/ -c kadm
echo "copy wulin-gcp/images ok"
kubectl cp ~/wulin-gcp/wkload/ kube-system/kube-kadm:/home/bigred/wulin/ -c kadm
echo "copy wulin-gcp/wkload ok"' 
