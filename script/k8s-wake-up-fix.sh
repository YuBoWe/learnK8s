#!/bin/bash
#
#********************************************************************
#Author:		    weiyubo
#QQ: 			    3424538465
#Date: 			    2026-02-07
#FileName：		    /usr/local/bin/k8s-wake-up-fix.sh
#URL: 			    weiyubo.cn
#Description：		The test script
#Copyright (C): 	2026 All rights reserved
#********************************************************************
# 唤醒后强制对时并清理 OpenELB 僵尸隐患
echo "System woke up, performing K8S self-healing..." >> /var/log/k8s-fix.log

# 1. 强制 Chrony 立即进行一次同步
chronyc -a makestep

# 2. 这里的等待很重要，等 API Server 重新连接 Etcd
sleep 5

# 3. 杀掉残留的僵尸进程父节点（如果有）
ps -ef | grep openelb-speaker | grep -v grep | awk '{print $2}' | xargs kill -9

# 4. 让 K8S 重新拉起组件
kubectl rollout restart ds openelb-speaker -n openelb-system
