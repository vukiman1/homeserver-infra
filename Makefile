export SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

SECRETS_FILE := secrets/prod.sops.yaml
SOPS_RUN := sops exec-env $(SECRETS_FILE)

.PHONY: secrets

secrets:
	sops $(SECRETS_FILE)

TOFU := tofu -chdir=tofu
PLAN_FILE := homeserver.tfplan

.PHONY: test tofu-init plan tofu-apply

test:
	.venv/bin/python -m pytest tests -q
	.venv/bin/python scripts/validate_apps.py
	$(TOFU) fmt -check -recursive
	$(TOFU) test

tofu-init:
	$(SOPS_RUN) '$(TOFU) init -input=false'

plan: tofu-init
	$(SOPS_RUN) '$(TOFU) plan -input=false -out=$(PLAN_FILE)'

tofu-apply:
	$(SOPS_RUN) '$(TOFU) apply -input=false $(PLAN_FILE)'

.PHONY: vm-up vm-test vm-down

vm-up:
	scripts/vm.sh up

vm-test: vm-up
	tests/test_deploy.sh
	tests/test_firewall.sh
	tests/test_backup.sh

vm-down:
	scripts/vm.sh down

ANSIBLE := ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/prod.yml ansible/site.yml
WITH_TUNNEL_TOKEN := TUNNEL_TOKEN="$$($(TOFU) output -raw tunnel_token)"

.PHONY: check deploy

check:
	$(SOPS_RUN) '$(WITH_TUNNEL_TOKEN) $(ANSIBLE) --check --diff $(ARGS)'

deploy:
	$(SOPS_RUN) '$(WITH_TUNNEL_TOKEN) $(ANSIBLE) $(ARGS)'

ANSIBLE_COLLECTIONS := $(shell brew --prefix ansible 2>/dev/null)/libexec/lib/python*/site-packages

.PHONY: lint

lint:
	yamllint .
	ANSIBLE_COLLECTIONS_PATH="$$(ls -d $(ANSIBLE_COLLECTIONS) 2>/dev/null)" ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/

ADMIN := ANSIBLE_CONFIG=ansible/ansible.cfg ansible -i ansible/inventory/prod.yml all -b
RESTORE := ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory/prod.yml ansible/restore.yml

.PHONY: backup-init backup restore

backup-init:
	$(SOPS_RUN) '$(WITH_TUNNEL_TOKEN) $(ANSIBLE) --tags backup -e backup_init=true'

backup:
	$(ADMIN) -m ansible.builtin.systemd_service -a "name=homeserver-backup.service state=started"

restore:
	$(RESTORE) $(if $(APPLY),-e restore_apply=true) $(if $(SNAPSHOT),-e restore_snapshot=$(SNAPSHOT))

FRESH_VM := VM_NAME=homeserver-fresh VM_STATE_DIR=.vm-fresh

.PHONY: vm-test-fresh

vm-test-fresh:
	$(FRESH_VM) scripts/vm.sh up
	tests/test_fresh_restore.sh

ADOPT_VM := VM_NAME=homeserver-adopt VM_STATE_DIR=.vm-adopt

.PHONY: vm-test-adoption

vm-test-adoption:
	$(ADOPT_VM) scripts/vm.sh up
	$(ADOPT_VM) tests/test_adoption.sh
	$(ADOPT_VM) REQUIRE_FRESH=1 tests/test_firewall.sh
