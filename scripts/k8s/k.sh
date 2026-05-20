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

# Connect to prompt-dev EKS and pin namespace to dev-ariel-ps
k_content() {
  aws eks update-kubeconfig --name prompt-dev --region eu-north-1 || return 1
  kubectl config set-context --current --namespace=dev-ariel-ps
}
