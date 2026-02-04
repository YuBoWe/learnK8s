helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/

helm install my-headlamp headlamp/headlamp --namespace kube-system -f my-values.yaml

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl patch deployment metrics-server -n kube-system --type 'json' -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
