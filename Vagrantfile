# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

WINDOWS_BOXES = {
  "DC01" => { box: "StefanScherer/windows_2019", ip: "192.168.10.10", memory: 4096, cpus: 2 },
  "FS01" => { box: "StefanScherer/windows_2019", ip: "192.168.10.20", memory: 4096, cpus: 2 },
  "WS01" => { box: "StefanScherer/windows_10",   ip: "192.168.10.50", memory: 4096, cpus: 2 },
}

def find_docker_bridge
  %w[target_net dragonrx].each do |filter|
    id = `docker network ls --filter name=#{filter} --format "{{.ID}}" 2>/dev/null`.strip.split.first
    return "br-#{id[0, 12]}" if id && !id.empty?
  end
  nil
end

DOCKER_BRIDGE = find_docker_bridge

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  config.vagrant.plugins = ["vagrant-reload", "vagrant-hostmanager"]

  # Ignore the box's packed Vagrantfile — it declares a synced folder and
  # runs a $username provisioner that fails on newer WinRM/Ruby. We set
  # all WinRM, network, and provisioner config ourselves.
  config.vm.ignore_box_vagrantfile = true

  config.hostmanager.enabled      = true
  config.hostmanager.manage_host  = false
  config.hostmanager.manage_guest = false  # Ansible sets hostnames + /etc/hosts

  WINDOWS_BOXES.each do |name, cfg|
    config.vm.define name do |node|
      node.vm.box = cfg[:box]
      # No vm.hostname — triggers mid-boot Windows reboot that stalls 15+ min
      # on the bridged NIC (no DHCP on Docker bridge). Ansible handles it.

      node.vm.synced_folder ".", "/vagrant", disabled: true

      node.vm.communicator       = "winrm"
      node.winrm.username        = "vagrant"
      node.winrm.password        = "vagrant"
      node.winrm.transport       = :negotiate
      node.winrm.basic_auth_only = false
      node.winrm.retry_limit     = 20
      node.winrm.retry_delay     = 10

      # NIC 1: NAT (internet / WinRM port forwarding)
      # NIC 2: bridged to Docker target_net bridge — auto_config false so
      # Vagrant doesn't trigger a reboot trying to set the IP via WinRM.
      # Static IP is set by the PowerShell provisioner below instead.
      abort "Docker target_net bridge not found — run 'docker compose up -d' first." unless DOCKER_BRIDGE
      node.vm.network "public_network",
        bridge:      DOCKER_BRIDGE,
        auto_config: false

      node.vm.provider "virtualbox" do |vb|
        vb.name   = "dragonrx_#{name.downcase}"
        vb.memory = cfg[:memory]
        vb.cpus   = cfg[:cpus]
        vb.gui    = false
        vb.customize ["modifyvm", :id, "--nested-hw-virt", "on"]
        vb.customize ["modifyvm", :id, "--clipboard",      "bidirectional"]
        # allow-all promiscuous mode on NIC2 (bridged to Docker target_net bridge)
        # Required so the VM forwards frames from Docker containers — without this
        # VirtualBox drops frames whose source MAC doesn't match the VM's own NIC.
        vb.customize ["modifyvm", :id, "--nicpromisc2",    "allow-all"]
      end

      # Set static IP on NIC2 (bridged adapter) without triggering a reboot.
      # Finds NIC2 by excluding the default-route adapter (NIC1 = NAT).
      node.vm.provision "shell", privileged: false,
        powershell_elevated_interactive: false,
        inline: <<~PS
          $defIdx = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
                     Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
          $nic2   = Get-NetAdapter |
                    Where-Object { $_.InterfaceIndex -ne $defIdx -and $_.Status -eq 'Up' } |
                    Select-Object -First 1
          if ($nic2) {
              Remove-NetIPAddress  -InterfaceIndex $nic2.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
              Remove-NetRoute      -InterfaceIndex $nic2.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
              New-NetIPAddress     -InterfaceIndex $nic2.InterfaceIndex `
                                   -IPAddress '#{cfg[:ip]}' -PrefixLength 24
              Write-Host "NIC2 configured: #{cfg[:ip]}/24"
          } else {
              Write-Host "WARNING: NIC2 not found (may still be initialising)"
          }
          Write-Host "VM #{name} ready for Ansible"
        PS
    end
  end
end
