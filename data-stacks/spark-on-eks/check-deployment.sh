# Set kubeconfig (done automatically by deploy.sh)
export KUBECONFIG=kubeconfig.yaml

# Verify cluster nodes
echo "---------------------------------------------------------------------"
echo "Verifying cluster nodes ... Expected: 4-5 nodes with STATUS=Ready \n"
echo "---------------------------------------------------------------------"
kubectl get nodes

# Check all namespaces
echo "---------------------------------------------------------------------"
echo "Verifying namespaces ... \n"
echo "---------------------------------------------------------------------"
kubectl get namespaces

# Verify ArgoCD applications
echo "---------------------------------------------------------------------"
echo "Verifying argocd applications ... \n"
echo "---------------------------------------------------------------------"
kubectl get applications -n argocd


# Verify Spark Operator is running
# Expected: spark-operator-controller and webhook pods Running
echo "---------------------------------------------------------------------"
echo "Verifying Spark Operator ... Expected: spark-operator-controller and webhook pods Running \n"
echo "---------------------------------------------------------------------"
kubectl get pods -n spark-operator


# 4. Verify Spark CRDs installed
# Expected: sparkapplications.sparkoperator.k8s.io
echo "---------------------------------------------------------------------"
echo "Verifying Spark CRDs installed ... Expected: sparkapplications.sparkoperator.k8s.io \n"
echo "---------------------------------------------------------------------"
kubectl get crds | grep spark

# 5. Check Karpenter NodePools ready
# Expected: 5 pools with READY=True
echo "---------------------------------------------------------------------"
echo "Verifying Karpenter NodePools ...  # Expected: 5 pools with READY=True\n"
echo "---------------------------------------------------------------------"
kubectl get nodepools
