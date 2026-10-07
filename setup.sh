#!/usr/bin/env bash
set -euo pipefail

export k8_scalar_dir="$PWD"
test -d "$k8_scalar_dir/operations" || { echo "Run this from the k8-scalar repo root"; exit 1; }

if [ "${SKIP_CLUSTER:-0}" != "1" ]; then
  # --- 0. Lift podman's per-container PID limit (needed for Scalar's threads) ---
  conf="$HOME/.config/containers/containers.conf"
  if ! grep -qs '^pids_limit' "$conf"; then
    mkdir -p "$(dirname "$conf")"
    if grep -qs '^\[containers\]' "$conf"; then
      sed -i '/^\[containers\]/a pids_limit = 0' "$conf"
    else
      printf '[containers]\npids_limit = 0\n' >> "$conf"
    fi
  fi

  # --- 1. Fresh minikube cluster ---
  minikube delete || true
  minikube config set rootless true
  minikube start --driver=podman --container-runtime=containerd --cpus 4 --memory 8192
  echo "PID limit of node container (want 0 or -1):"
  podman inspect minikube --format '{{.HostConfig.PidsLimit}}'
fi

kubectl config use-context minikube
kubectl wait --for=condition=Ready node/minikube --timeout=120s

# --- Cleanup of leftovers from earlier attempts (safe on a fresh cluster) ---
helm list -A -a | awk 'NR>1 {print $1, $2}' | while read -r name ns; do
  helm uninstall "$name" -n "$ns" || true
done
for r in $(kubectl get clusterrole -o name | grep -i heapster || true); do
  kubectl delete "$r"
done
for r in $(kubectl get clusterrolebinding -o name | grep -i heapster || true); do
  kubectl delete "$r"
done
kubectl delete secret kubeconfig --ignore-not-found
kubectl delete secret kubeconfig -n kube-system --ignore-not-found

# --- 2. Monitoring (Heapster, Grafana, InfluxDB) ---
helm install "$k8_scalar_dir/operations/monitoring-core" --generate-name --namespace=kube-system
kubectl -n kube-system wait --for=condition=Available deployment --all --timeout=300s

# --- 3. Cassandra ---
helm install "$k8_scalar_dir/operations/cassandra-cluster" --generate-name
until kubectl get pod cassandra-0 >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Ready pod/cassandra-0 --timeout=600s

# --- 4. Kubeconfig secret for the experiment-controller ---
rm -rf "$k8_scalar_dir/operations/secrets"
mkdir -p "$k8_scalar_dir/operations/secrets"
cd "$k8_scalar_dir/operations/secrets"
cp ~/.kube/config .
cp ~/.minikube/ca.crt .
cp ~/.minikube/profiles/minikube/client.crt .
cp ~/.minikube/profiles/minikube/client.key .
# cert paths -> where the secret is mounted inside the pod (profiles path first!)
sed -i "s#$HOME/.minikube/profiles/minikube/#/root/.kube/#g" ./config
sed -i "s#$HOME/.minikube/#/root/.kube/#g" ./config
# API address: the rootless 127.0.0.1:<port> is unreachable from inside a pod
sed -i 's#server: .*#server: https://kubernetes.default.svc:443#' ./config
kubectl create secret generic kubeconfig --from-file .
cd "$k8_scalar_dir"

# --- 5. Experiment controller ---
helm install "$k8_scalar_dir/operations/experiment-controller" --generate-name
until kubectl get pod experiment-controller-0 >/dev/null 2>&1; do sleep 2; done
kubectl wait --for=condition=Ready pod/experiment-controller-0 --timeout=300s
kubectl exec experiment-controller-0 -- kubectl get nodes   # sanity check: pod can reach the API

# --- 6. Small smoke-test run (scale up once this works) ---
echo "To run the stress test:"
echo "kubectl exec experiment-controller-0 -- bash bin/stress.sh --duration 60 50:150:50"
echo "kubectl exec experiment-controller-0 -- ls /exp/var/results"
echo "rm -rf ./results"
echo "kubectl cp experiment-controller-0:/exp/var/results ./results"
