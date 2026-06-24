# k3s-on-vSphere lab — repeatable environment
# One-command lifecycle: make up / make down / make rebuild
#
# Requires: terraform, ansible, jq, ssh, and a populated
# terraform/terraform.tfvars (copy from terraform.tfvars.example).

TF_DIR    := terraform
ANSIBLE   := ansible
SCRIPTS   := scripts

.PHONY: help install-prereqs setup quick init plan up provision configure down rebuild clean validate

help:
	@echo "Targets:"
	@echo "  install-prereqs - install/upgrade terraform, ansible, jq, git on this controller (Debian/Ubuntu)"
	@echo "  up        - interactive: prompt for inputs (saved values shown as editable defaults), then provision + configure"
	@echo "  quick     - non-interactive: reuse saved terraform.tfvars as-is (no prompts), then provision + configure"
	@echo "  setup     - interactive: collect inputs and write terraform.tfvars only (no provisioning)"
	@echo "  init      - terraform init"
	@echo "  validate  - terraform validate"
	@echo "  provision - terraform apply only (create the VMs)"
	@echo "  configure - render inventory + run ansible (cluster + app)"
	@echo "  down      - terraform destroy (tear down all VMs)"
	@echo "  rebuild   - down then up (fresh environment)"
	@echo "  clean     - remove generated inventory/kubeconfig"

install-prereqs:
	bash $(SCRIPTS)/install-prereqs.sh

setup:
	bash $(SCRIPTS)/setup.sh

quick:
	SETUP_SKIP_RUN=1 bash $(SCRIPTS)/setup.sh --quick
	$(MAKE) provision
	$(MAKE) configure
	@echo "Environment is up. kubeconfig written to ansible/kubeconfig"

init:
	cd $(TF_DIR) && terraform init

validate: init
	cd $(TF_DIR) && terraform validate

provision: init
	bash $(SCRIPTS)/tf.sh apply -auto-approve

configure:
	bash $(SCRIPTS)/render-inventory.sh
	cd $(ANSIBLE) && ansible-playbook site.yml

up:
	SETUP_SKIP_RUN=1 bash $(SCRIPTS)/setup.sh
	$(MAKE) provision
	$(MAKE) configure
	@echo "Environment is up. kubeconfig written to ansible/kubeconfig"

down:
	bash $(SCRIPTS)/tf.sh destroy -auto-approve

rebuild: down up

clean:
	rm -f $(ANSIBLE)/inventory $(ANSIBLE)/kubeconfig
