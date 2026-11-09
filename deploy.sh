export DO_REGION=atl1
export DO_SSH_KEY_FINGERPRINT=60454848
export DO_CONTROL_PLANE_MACHINE_TYPE=gpu-mi300x1-192gb-devcloud
export DO_CONTROL_PLANE_MACHINE_IMAGE=252012821 # created in the step above.
export DO_NODE_MACHINE_TYPE=gpu-mi300x1-192gb-devcloud
export DO_NODE_MACHINE_IMAGE=252012821 # created in the step above.

clusterctl generate cluster capdo-quickstart \
    --infrastructure digitalocean \
    --kubernetes-version v1.32.0 \
    --control-plane-machine-count 1 \
    --worker-machine-count 3 > capdo-quickstart-cluster.yaml
