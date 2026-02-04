#!/bin/bash
#
#********************************************************************
#Author:		    weiyubo
#QQ: 			    3424538465
#Date: 			    2026-02-04
#FileName：		    test.sh
#URL: 			    weiyubo.cn
#Description：		The test script
#Copyright (C): 	2026 All rights reserved
#********************************************************************
# 检查是否输入了 Namespace
if [ -z "$1" ]; then
  echo "使用方法: ./find_unused_pvc.sh <namespace>"
  exit 1
fi

NS=$1

echo "--- 正在检查 Namespace [$NS] 下闲置的 PVC ---"

# 1. 获取该命名空间下所有已绑定的 PVC
ALL_PVCs=$(kubectl get pvc -n $NS --no-headers | awk '{print $1}')

# 2. 获取该命名空间下所有 Pod 正在使用的 PVC 列表
USED_PVCs=$(kubectl get pods -n $NS -o jsonpath='{.items[*].spec.volumes[*].persistentVolumeClaim.claimName}' | tr ' ' '\n' | sort | uniq)

# 3. 对比找出未被使用的 PVC
for pvc in $ALL_PVCs; do
    if ! echo "$USED_PVCs" | grep -q "^$pvc$"; then
        echo "[闲置] PVC: $pvc"
    fi
done

echo "------------------------------------------"
echo "--- 正在集群中搜索状态为 [Released] 的 PV ---"

# 获取状态为 Released 的 PV 名称
RELEASED_PVs=$(kubectl get pv --no-headers | awk '$5 == "Released" {print $1}')

if [ -z "$RELEASED_PVs" ]; then
  echo "未发现 Released 状态的 PV。"
else
  echo "以下 PV 已释放但未删除 (Retain 策略):"
  echo "$RELEASED_PVs"
fi

echo "------------------------------------------"
