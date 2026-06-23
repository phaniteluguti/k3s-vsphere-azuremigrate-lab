# k3s-on-vSphere lab — repeatable environment
# One-command lifecycle: make up / make down / make rebuild
#
# Requires: terraform, ansible, jq, ssh, and a populated
# terraform/terraform.tfvars (copy from terraform.tfvars.example).

TF_DIR    := terraform
ANSIBLE   := ansible
SCRIPTS   := scripts

.PHONY: help install-prereqs setup init plan up provision configure down rebuild clean validate

help:
	@echo "Targets:"
	@echo "  install-prereqs - install/upgrade terraform, ansible, jq, git on this controller (Debian/Ubuntu)"
	@echo "  setup     - interactive: collect inputs and write terraform.tfvars"
	@echo "  init      - terraform init"
	@echo "  validate  - terraform validate"
	@echo "  up        - provision VMs + configure cluster + deploy app"
	@echo "  provision - terraform apply only (create the 3 VMs)"
	@echo "  configure - render inventory + run ansible (cluster + app)"
	@echo "  down      - terraform destroy (tear down all VMs)"
	@echo "  rebuild   - down then up (fresh environment)"
	@echo "  clean     - remove generated inventory/kubeconfig"

install-prereqs:
	$(SCRIPTS)/install-prereqs.sh

setup:
	$(SCRIPTS)/setup.sh

init:
	cd $(TF_DIR) && terraform init

validate: init
	cd $(TF_DIR) && terraform validate

provision: init
	cd $(TF_DIR) && terraform apply -auto-approve

configure:
	$(SCRIPTS)/render-inventory.sh
	cd $(ANSIBLE) && ansible-playbook site.yml

up: provision configure
	@echo "Environment is up. kubeconfig written to ansible/kubeconfig"

down:
	cd $(TF_DIR) && terraform destroy -auto-approve

rebuild: down up

clean:
	rm -f $(ANSIBLE)/inventory $(ANSIBLE)/kubeconfig
