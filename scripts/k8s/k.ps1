# kubectl aliases (Windows) — mirrors k.sh

Set-Alias k kubectl

# Workloads
function kpod  { kubectl get pods @args }
function kdep  { kubectl get deployments @args }
function krs   { kubectl get replicasets @args }
function ksts  { kubectl get statefulsets @args }
function kds   { kubectl get daemonsets @args }
function kjob  { kubectl get jobs @args }
function kcron { kubectl get cronjobs @args }

# Networking
function ksvc  { kubectl get services @args }
function king  { kubectl get ingress @args }
function kep   { kubectl get endpoints @args }
function knp   { kubectl get networkpolicies @args }

# Config & storage
function kcm   { kubectl get configmaps @args }
function ksec  { kubectl get secrets @args }
function kpv   { kubectl get persistentvolumes @args }
function kpvc  { kubectl get persistentvolumeclaims @args }

# Cluster
function kns   { kubectl get namespaces @args }
function kno   { kubectl get nodes @args }
function kev   { kubectl get events --sort-by=.lastTimestamp @args }

# Common verbs
function kdesc { kubectl describe @args }
function klog  { kubectl logs @args }
function klogf { kubectl logs -f @args }
function kexec { kubectl exec -it @args }
function kapp  { kubectl apply -f @args }
function kdel  { kubectl delete @args }
function kctx  { kubectl config current-context }

# Connect to an EKS cluster and optionally pin a namespace.
# usage: k_connect <cluster-name> <region> [namespace]
function k_connect {
    param(
        [Parameter(Mandatory)][string]$Cluster,
        [Parameter(Mandatory)][string]$Region,
        [string]$Namespace
    )
    aws eks update-kubeconfig --name $Cluster --region $Region
    if ($LASTEXITCODE) { return }
    if ($Namespace) { kubectl config set-context --current --namespace=$Namespace }
}
