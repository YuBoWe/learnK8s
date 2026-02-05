# 问题描述
命令top发现大量僵尸进程
如下：
```
root@worker4:~# top
top - 12:03:37 up 18 days, 23:32,  2 users,  load average: 0.04, 0.14, 0.16
Tasks: 2126 total,   1 running, 225 sleeping,   0 stopped, 1900 zombie
%Cpu(s):  4.5 us, 13.6 sy,  0.0 ni, 81.8 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st
MiB Mem :   1967.2 total,     39.0 free,    806.7 used,   1121.5 buff/cache
MiB Swap:      0.0 total,      0.0 free,      0.0 used.   1063.0 avail Mem 
```
# 问题排查
使用ps命令找到生产僵尸进程的父进程
```sh
ps -ef | jgrep 'defunct' | head -n 20
```
如下：
```
root     3428472 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3498574 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3507888 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3507972 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508061 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508082 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508165 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508236 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508314 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508393 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508479 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508586 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508649 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508707 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508754 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508838 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3508920 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3509004 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3509094 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
root     3510347 3428344  0 Feb04 ?        00:00:00 [gobgp] <defunct>
```
随即查看生产的应用
```sh
ps -f -p 3510347
# UID          PID    PPID  C STIME TTY          TIME CMD
# root     3428344 3428288  4 Feb04 ?        00:44:21 openelb-speaker --api-hosts=:50051 --enable-keepalived-vip=false --enable-layer2=true
```
# 解决方案
先kill
```
kill -9 3428288
```


```sh
观察滚动更新
```sh
kubectl get pod -n openelb-system -w
```
