output "server_node" {
  description = "Name and IP of the k3s server node."
  value = {
    for name, vm in vsphere_virtual_machine.node :
    name => local.static ? local.node_ip[name] : vm.default_ip_address
    if can(regex("-server$", name))
  }
}

output "agent_nodes" {
  description = "Names and IPs of the k3s agent nodes."
  value = {
    for name, vm in vsphere_virtual_machine.node :
    name => local.static ? local.node_ip[name] : vm.default_ip_address
    if can(regex("-agent-", name))
  }
}

output "all_nodes" {
  description = "All node names mapped to their primary IP address."
  value = {
    for name, vm in vsphere_virtual_machine.node :
    name => local.static ? local.node_ip[name] : vm.default_ip_address
  }
}
