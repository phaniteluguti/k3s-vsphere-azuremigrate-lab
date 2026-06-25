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

write_files:
  # Configure networking by writing netplan directly instead of relying on
  # cloud-init's network rendering. Ubuntu templates built from the live-server
  # (subiquity) ISO ship `network: {config: disabled}`, which makes cloud-init
  # ignore the datasource network config and keep the template's DHCP netplan.
  # write_files + runcmd run regardless of that setting, so this works on any
  # template and gives the node its predictable static IP (or DHCP).
  - path: /etc/netplan/99-k3s.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          nic0:
            match:
              name: "e*"
            dhcp4: ${dhcp4}
%{ if dhcp4 == "false" ~}
            addresses:
              - ${ip}/${prefix}
            routes:
              - to: default
                via: ${gateway}
            nameservers:
              addresses: [${dns}]
%{ endif ~}

runcmd:
  # Remove any installer/cloud-init netplan files so only ours is active, then
  # apply it. Safe at first boot: there is no SSH session yet to drop.
  - find /etc/netplan -maxdepth 1 -type f ! -name '99-k3s.yaml' -delete
  - chmod 0600 /etc/netplan/99-k3s.yaml
  - netplan apply
  # Disable swap immediately (required by k3s/kubelet).
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
