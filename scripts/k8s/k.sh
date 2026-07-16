# kubectl aliases — `k<resource>` → `kubectl get <resource>`
# Pass any extra args through (e.g. `kpod -n kube-system -o wide`).

alias k='kubectl'

# Workloads
alias kpod='kubectl get pods'
alias kdep='kubectl get deployments'
alias krs='kubectl get replicasets'
alias ksts='kubectl get statefulsets'
alias kds='kubectl get daemonsets'
alias kjob='kubectl get jobs'
alias kcron='kubectl get cronjobs'

# Networking
alias ksvc='kubectl get services'
alias king='kubectl get ingress'
alias kep='kubectl get endpoints'
alias knp='kubectl get networkpolicies'

# Config & storage
alias kcm='kubectl get configmaps'
alias ksec='kubectl get secrets'
alias kpv='kubectl get persistentvolumes'
alias kpvc='kubectl get persistentvolumeclaims'

# Cluster
alias kns='kubectl get namespaces'
alias kno='kubectl get nodes'
alias kev='kubectl get events --sort-by=.lastTimestamp'

# Common verbs
alias kdesc='kubectl describe'
alias klog='kubectl logs'
alias klogf='kubectl logs -f'
alias kexec='kubectl exec -it'
alias kapp='kubectl apply -f'
alias kdel='kubectl delete'
alias kctx='kubectl config current-context'

# List pods and their container images, one row per container.
# usage: kpod-image [namespace] [extra kubectl args...]
#   namespace defaults to dev-ariel-ps; pass another name to override.
kpod-image() {
  local ns="${1:-dev-ariel-ps}"
  [[ $# -gt 0 ]] && shift
  kubectl get pods -n "$ns" "$@" -o json \
    | jq -r '.items[] | .metadata.name as $n | .spec.containers[] | "\($n)\t\(.image)"' \
    | column -t -s$'\t'
}

# Connect to an EKS cluster and optionally pin a namespace.
# usage: k_connect <cluster-name> <region> [namespace]
k_connect() {
  local cluster="${1:?usage: k_connect <cluster-name> <region> [namespace]}"
  local region="${2:?usage: k_connect <cluster-name> <region> [namespace]}"
  local ns="${3:-}"
  aws eks update-kubeconfig --name "$cluster" --region "$region" || return 1
  [[ -n "$ns" ]] && kubectl config set-context --current --namespace="$ns"
}
