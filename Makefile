#################################
# https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
# 	The regex has been altered for flexibility.
.PHONY: help
help:
	@grep -E '^[0-9a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
.DEFAULT_GOAL := help
#################################
CLUSTER_NAME := edu
RESOURCES    := ./STARTUP_RESOURCES
#
# This Makefile is designed to make it easy to create and destroy
# the cluster in parts.
# Delays are introduced, in case the user gets impatient and
# tries to create things too quickly (before things are ready).
#
.PHONY: create
# https://support.jamasoftware.com/hc/en-us/articles/25363403125517-Failed-to-create-fsnotify-watcher-too-many-open-files
1-create: FS_INOTIFY := 1100100
1-create: ## "edu" class-use Kind cluster.
	@echo "******* Temporarily setting open files to rediculous values (this will sudo)"
	@echo "******* This Makefile was written on XUbuntu 24.04.4 LTS"
	sudo sysctl -w fs.inotify.max_user_watches=$(FS_INOTIFY)
	sudo sysctl -w fs.inotify.max_user_instances=$(FS_INOTIFY)
	sudo sysctl -w fs.inotify.max_queued_events=$(FS_INOTIFY)
	kind create cluster --name $(CLUSTER_NAME) --config $(RESOURCES)/edu-cluster.yaml
	kubectl get all -A
	kubectl get nodes
	kubectl cluster-info --context kind-edu
	./bin/wait-4-healthy-pods.sh
	@echo '#### Cluster created. Start k9s now, so you can watch next steps.  (make k9s-all-pods)'
	@echo '   *** It is SUPER IMPORTANT to pay attention to error messages in next steps. ***'

.PHONY: 1a-install-metrics-server
1a-install-metrics-server: IMS_URL := https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
1a-install-metrics-server: ## Optionally: install metrics-server
	kubectl apply -f $(IMS_URL)
	kubectl patch deployment metrics-server -n kube-system --type=json -p='[ \
  		{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}, \
  		{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"} \
	]'
	./bin/wait-4-healthy-pods.sh
	@echo "When this starts, you can 'kubectl top nodes'"

# CALICO_OPERATOR_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml"
2-add-cni: CALICO_OPERATOR_MANIFEST := "$(RESOURCES)/tigera-operator.yaml"
2-add-cni: ## Add Calico CNI (Container Network Interface - after cluster create)
	kubectl apply -f $(CALICO_OPERATOR_MANIFEST) --server-side --force-conflicts
	kubectl apply -f $(RESOURCES)/calico-custom-config.yaml --server-side --field-manager=calico-config
	kubectl apply -f $(RESOURCES)/dnsutils.yaml
	@echo "WAITING ~3 long MINUTES: Let Calico spin up."
	@echo "You have the option of shelling in for diags: kubectl -n kube-tools exec -it dnsutils -- /bin/bash"
	./bin/wait-4-healthy-pods.sh
	kubectl get all -A

.PHONY: add-metallb
3-add-metallb:  ## Add the MetalLB load balancer (after Calico)
	@echo "Ensuring kubectl \"strictARP: true"
	- kubectl get configmap kube-proxy -n kube-system -o yaml | \
		sed -e "s/strictARP: false/strictARP: true/" | \
		kubectl apply -f -
	kubectl get configmap kube-proxy -n kube-system -o yaml | grep -iE 'strictARP|ipvs' | grep -v apiVersion
	kubectl rollout restart daemonset kube-proxy -n kube-system
	@echo "WAITING a few SECONDS: Let kube-proxy restart"
	./bin/wait-4-healthy-pods.sh 5
	helm repo add metallb https://metallb.github.io/metallb
	helm repo update
	helm install metallb metallb/metallb --namespace metallb-system --create-namespace
	@echo "WAITING ~3 long MINUTES: Let metallb spin up. "
	@echo "  While you wait: check to make sure that metallb-conf.yaml is using"
	@echo "    a small pool of unused IPs in the same range as your 'real' host."
	@echo "    And, just as important: ensure it binds to the correct network."
	@echo "    See metallb-conf.yaml for a hint."
	./bin/wait-4-healthy-pods.sh
	- kubectl apply -f $(RESOURCES)/metallb-conf.yaml
	@echo "*** If you got an error for the kubectl apply above, wait a minute and try it again."
	@sleep 3
	docker inspect kind | grep "Subnet"
	@echo "*** spec.addresses **MUST BE** in your 'real' machine's subnet"
	@echo "*** Make sure the address pools in the next two commands match."
	kubectl -n metallb-system  get ipaddresspool -o json | jq '.items[0].spec.addresses'
	docker network inspect kind -f '{{range.Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'

.PHONY: add-headlamp
4-add-headlamp: tokens := "headlamp.tokens"
4-add-headlamp:  ## Add the K8s SIG Headlamp utility (after MetalLB)
	helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
	helm repo update
	helm install headlamp headlamp/headlamp --namespace headlamp --create-namespace --set service.type=LoadBalancer
	kubectl -n headlamp get all
	kubectl -n headlamp get svc headlamp
	kubectl -n headlamp create serviceaccount headlamp-admin 
	kubectl -n headlamp create serviceaccount headlamp-read-only
	kubectl create clusterrolebinding headlamp-admin-binding \
		--clusterrole=cluster-admin \
		--serviceaccount=headlamp:headlamp-admin
	kubectl create clusterrolebinding headlamp-read-only-binding \
		--clusterrole=view \
		--serviceaccount=headlamp:headlamp-read-only
	@echo "# Admin token (24h ttl)" | tee $(tokens)
	kubectl -n headlamp create token headlamp-admin --duration 86400s | tee -a $(tokens)
	@echo "\n# RO token (infinite ttl)" | tee -a $(tokens)
	kubectl -n headlamp create token headlamp-read-only | tee -a $(tokens)
	@echo "" >> $(tokens)
	@echo "Saved tokens to $(tokens)"
	kubectl -n headlamp get all
	kubectl -n headlamp get svc headlamp

.PHONY: add-ingress
5-add-ingress:  ### Install the nginx ingress (after headlamp)
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update
	helm install my-nginx-ingress ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
	kubectl -n ingress-nginx get all
	kubectl -n ingress-nginx get svc
	# helm uninstall my-nginx-ingress --namespace ingress-nginx

.PHONY:
uninstall-headlamp: ## Completely remove headlamp.
	- kubectl -n headlamp delete sa headlamp-read-only
	- kubectl -n headlamp delete sa headlamp-admin
	- kubectl delete clusterrolebinding headlamp-admin-binding
	- kubectl delete clusterrolebinding headlamp-read-only-binding
	- helm uninstall headlamp --namespace headlamp
	- kubectl delete ns headlamp	

destroy: delete
.PHONY: delete
delete: ## Delete the "edu" Kind cluster.
	kind delete cluster --name $(CLUSTER_NAME)
	@echo "Let things \"cool\" for a few minutes before doing another 'make create'"

.PHONY: mon-cluster
mon-cluster: ## Overall monitoring of the cluster
	@echo -e '\n\n#####\n#####\n'
	@kubectl cluster-info
	@echo
	@kubectl get nodes -o wide --show-labels
	@echo
	@kubectl get all -A -o wide
	@echo
	@kubectl get pc

.PHONY: k9s-all-pods
k9s-all-pods: ## Watch all pods in all namespaces
	k9s -A -c pod

.PHONY: dnsutils
dnsutils: ## Shell into the dnsutils pod and dig around.
	kubectl -n kube-tools exec -it dnsutils -- /bin/bash

.PHONY: ipv4-in-use
ipv4-in-use: MY_CIDR := $(shell ip addr | grep -E 'inet .* global dynamic ' | awk '{print $$2}')
ipv4-in-use: ## Get in-use IPv4 addresses (for config of metallb, maybe?)
	sudo nmap -sn -n -oG - $(MY_CIDR) 2>/dev/null | grep -iv nmap | awk '{print $$2}' | sort -V

check-push: checkpush
.PHONY: checkpush
checkpush: ## Find modified files, add, commit and push
	@files=$$(git status --porcelain | awk 'substr($$0, 1, 2) ~ /M/ {print substr($$0, 4)}'); \
	if [ -z "$$files" ]; then \
		echo "No modified files to commit."; \
		exit 0; \
	fi; \
	git add -- $$files; \
	git commit -m "Checkpoint $$(date +%Y%m%d.%H%M)"
	git push
	git status

.PHONY: build-utils
build-utils: VERSION := $(shell date +%Y%m%d%H%M)
build-utils: BASE_TAG := "tsutils"
build-utils: ## Build our own network troubleshooting container
	@echo Nothing here yet.
	docker build --platform linux/amd64 --progress=plain --no-cache \
		--tag $(BASE_TAG):$(VERSION) \
		. -f Dockerfile.tsutils
	docker images

