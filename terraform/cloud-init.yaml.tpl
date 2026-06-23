#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
manage_etc_hosts: true
preserve_hostname: false

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}

# Disable swap immediately (required by k3s/kubelet).
runcmd:
  - swapoff -a
  - sed -i '/\sswap\s/d' /etc/fstab
  - systemctl restart systemd-timesyncd || true

package_update: true
packages:
  - open-vm-tools
  - curl
  - chrony

power_state:
  mode: reboot
  condition: false
