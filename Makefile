.PHONY: up down reset test attack status logs shell deps

ANSIBLE_DIR    := ansible
PLAYBOOK_FLAGS := -v

# ─────────────────────────────────────────────────────────────────────────────
up: deps
	@echo "==> [1/5] Building rxphage implant (Linux ELF + Windows PE)..."
	docker compose build rxphage_builder
	@echo "==> [2/5] Starting Docker services..."
	docker compose up -d
	@echo "    Waiting for Wazuh to initialise..."
	@until docker exec dragonrx_wazuh pgrep wazuh-analysisd >/dev/null 2>&1; do sleep 5; done
	@docker cp siem/wazuh/rules/dragonrx_rules.xml dragonrx_wazuh:/var/ossec/etc/rules/ 2>/dev/null || true
	@docker exec dragonrx_wazuh /var/ossec/bin/wazuh-control restart >/dev/null 2>&1 || true
	@echo "==> [3/5] Configuring host routing (Docker ↔ VirtualBox)..."
	bash scripts/setup_routing.sh
	@echo "==> [4/5] Starting Windows VMs..."
	vagrant up --provider virtualbox
	@echo "==> [5/5] Running Ansible provisioning..."
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/deploy.yml $(PLAYBOOK_FLAGS)
	@echo ""
	@echo "==> Lab ready."
	@echo "    Kibana : http://localhost:5601"
	@echo "    Kali   : make shell"
	@echo "    Sliver : docker exec -it dragonrx_c2 sliver"

down:
	vagrant halt
	docker compose down
	@echo "==> Lab stopped. Data volumes preserved."

reset:
	@echo "==> Full reset — destroying all state..."
	-vagrant destroy -f
	docker compose down -v
	@echo "==> Done. Run 'make up' to redeploy."

test:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/test.yml $(PLAYBOOK_FLAGS)

attack:
	docker exec -it dragonrx_kali bash /opt/tools/run_attack.sh

# ─────────────────────────────────────────────────────────────────────────────
status:
	@echo "--- Docker ---"
	docker compose ps
	@echo ""
	@echo "--- Vagrant ---"
	vagrant status

logs:
	docker compose logs -f --tail=50

shell:
	docker exec -it dragonrx_kali /bin/bash

# Re-start Sliver C2 listeners after a server restart (listeners are not persisted)
listeners:
	@echo "==> Starting HTTP and HTTPS listeners on dragonrx_c2..."
	@docker exec -i dragonrx_c2 sh -c \
	  "CFG=\$$(ls /root/.sliver-client/configs/*.cfg 2>/dev/null | head -1) && \
	   printf 'http --lhost 0.0.0.0 --lport 80\nhttps --lhost 0.0.0.0 --lport 443\njobs\nexit\n' \
	   | /usr/local/bin/sliver --config \"\$$CFG\" 2>/dev/null || true"
	@echo "==> Listeners started. Run 'make sliver' to verify."

sliver:
	docker exec -it dragonrx_c2 sliver

deps:
	@command -v docker     >/dev/null 2>&1 || (echo "ERROR: docker not found"     && exit 1)
	@docker compose version >/dev/null 2>&1 || (echo "ERROR: 'docker compose' (v2 plugin) not found — upgrade Docker Desktop or install the compose plugin" && exit 1)
	@command -v vagrant    >/dev/null 2>&1 || (echo "ERROR: vagrant not found"    && exit 1)
	@command -v ansible    >/dev/null 2>&1 || (echo "ERROR: ansible not found — pip3 install ansible" && exit 1)
	@command -v VBoxManage >/dev/null 2>&1 || (echo "ERROR: VBoxManage not found" && exit 1)
	@python3 -c "import winrm" 2>/dev/null || (echo "ERROR: pywinrm not installed — pip3 install pywinrm" && exit 1)
	@vagrant plugin list 2>/dev/null | grep -q vagrant-reload     || (echo "ERROR: vagrant plugin 'vagrant-reload' missing — vagrant plugin install vagrant-reload" && exit 1)
	@vagrant plugin list 2>/dev/null | grep -q vagrant-hostmanager || (echo "ERROR: vagrant plugin 'vagrant-hostmanager' missing — vagrant plugin install vagrant-hostmanager" && exit 1)
	@vagrant box list 2>/dev/null | grep -q "StefanScherer/windows_2019" || \
		(echo "WARN: Vagrant box StefanScherer/windows_2019 not cached locally — 'vagrant up' will download it (~8 GB)")
	@vagrant box list 2>/dev/null | grep -q "StefanScherer/windows_10" || \
		(echo "WARN: Vagrant box StefanScherer/windows_10 not cached locally — 'vagrant up' will download it (~8 GB)")
	@echo "[+] All prerequisites satisfied."
