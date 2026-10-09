SHELL := /bin/bash
ANSIBLE_DIR := ansible

.PHONY: help prepare k8s post-k8s argocd all destroy password

help:
	@echo "Targets:"
	@echo "  prepare   - 01-prepare.yml (common OS setup)"
	@echo "  k8s       - 02-run-kubespray.sh (install Kubernetes)"
	@echo "  post-k8s  - 03-post-kubespray.yml (kubeconfig + labels)"
	@echo "  argocd    - 04-argocd.yml (bootstrap ArgoCD)"
	@echo "  all       - full bootstrap"
	@echo "  destroy   - destroy cluster (VMs remain)"
	@echo "  password  - print ArgoCD admin password"

prepare:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/01-prepare.yml

k8s:
	./scripts/02-run-kubespray.sh

post-k8s:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/03-post-kubespray.yml

argocd:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/04-argocd.yml

all:
	./scripts/bootstrap.sh

destroy:
	./scripts/destroy.sh

password:
	./scripts/get-argocd-password.sh