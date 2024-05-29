# 1. 下載 kindctl 並賦予執行權限

```
curl -s https://raw.githubusercontent.com/braveantony/bash-script/main/kind/kindctl -O && \
sudo chmod +x ./kindctl
```


# 2. Quick Start

```
## Descriptions:
  啟動或關閉 Kind Clusters

## Usage:
  kindctl [options] <Cluster Name>

## Available options:
  start:
        啟動指定的 Kind 叢集。
  stop:
        關閉指定的 Kind 叢集。
  -h|--help:
        show this help text.

## Examples:
  # 啟動 c30 叢集的所有 nodes
  ./kindctl start c30
  All nodes in c30 Cluster are Running.

  # 關閉 c30 叢集的所有 nodes
  ./kindctl stop c30
  All nodes in c30 Cluster are Stopped.

  # 關閉 c30 和 c29 叢集的所有 nodes
  ./kindctl stop c30 start c29
  All nodes in c30 Cluster are Stopped.
  All nodes in c29 Cluster are Stopped.
```
