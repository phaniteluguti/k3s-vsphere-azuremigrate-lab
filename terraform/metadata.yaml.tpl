instance-id: ${hostname}
local-hostname: ${hostname}
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
