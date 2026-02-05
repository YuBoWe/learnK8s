#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

echo -e "${YELLOW}--- 正在检查 K8s 全空间 Pod 运行状态 ---${NC}"
echo "--------------------------------------------------------"
printf "%-25s %-40s %-15s %-10s\n" "NAMESPACE" "POD_NAME" "STATUS" "RESTARTS"

# 获取所有 Pod 信息
kubectl get pods -A --no-headers | while read -r line; do
    NAMESPACE=$(echo $line | awk '{print $1}')
    NAME=$(echo $line | awk '{print $2}')
    READY=$(echo $line | awk '{print $3}')
    STATUS=$(echo $line | awk '{print $4}')
    RESTARTS=$(echo $line | awk '{print $5}')

    # 判断状态是否正常
    if [[ "$STATUS" == "Running" && "$READY" == *"/"* ]]; then
        # 拆分 Ready 字段，例如 1/1
        READY_NOW=$(echo $READY | cut -d'/' -f1)
        READY_TOTAL=$(echo $READY | cut -d'/' -f2)
        
        if [ "$READY_NOW" -eq "$READY_TOTAL" ]; then
            COLOR=$GREEN
        else
            COLOR=$YELLOW
        fi
    else
        COLOR=$RED
    fi

    # 打印结果
    printf "${COLOR}%-25s %-40s %-15s %-10s${NC}\n" "$NAMESPACE" "$NAME" "$STATUS" "$RESTARTS"
done

echo "--------------------------------------------------------"
echo -e "${YELLOW}检查结束。如有红色项，请执行: kubectl describe pod <pod_name> -n <ns>${NC}"
