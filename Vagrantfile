# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

WINDOWS_BOXES = {
  "DC01" => { box: "StefanScherer/windows_2019", ip: "192.168.10.10", memory: 4096, cpus: 2 },
  "FS01" => { box: "StefanScherer/windows_2019", ip: "192.168.10.20", memory: 4096, cpus: 2 },
  "WS01" => { box: "StefanScherer/windows_10",   ip: "192.168.10.50", memory: 4096, cpus: 2 },
}

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  config.vagrant.plugins = ["vagrant-reload", "vagrant-hostmanager"]

  config.hostmanager.enabled      = true
  config.hostmanager.manage_host  = true
  config.hostmanager.manage_guest = true

  WINDOWS_BOXES.each do |name, cfg|
    config.vm.define name do |node|
      node.vm.box      = cfg[:box]
      node.vm.hostname = name.downcase

      node.vm.communicator       = "winrm"
      node.winrm.username        = "vagrant"
      node.winrm.password        = "vagrant"
      node.winrm.transport       = :negotiate
      node.winrm.basic_auth_only = false

      # NIC 1: NAT (internet / box download)
      # NIC 2: host-only — lab network 192.168.10.0/24
      node.vm.network "private_network",
        ip:   cfg[:ip],
        name: "vboxnet0"

      node.vm.provider "virtualbox" do |vb|
        vb.name   = "dragonrx_#{name.downcase}"
        vb.memory = cfg[:memory]
        vb.cpus   = cfg[:cpus]
        vb.gui    = false
        vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
        vb.customize ["modifyvm", :id, "--clipboard",      "bidirectional"]
      end

      node.vm.provision "shell",
        inline:    "Write-Host 'VM #{name} ready for Ansible'",
        privileged: true,
        powershell_elevated_interactive: false
    end
  end
end
