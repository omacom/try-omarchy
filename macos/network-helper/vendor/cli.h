#ifndef SOCKET_VMNET_CLI_H
#define SOCKET_VMNET_CLI_H

#include <uuid/uuid.h>

#include <vmnet/vmnet.h>

struct cli_options {
  // --socket-group
  char *socket_group;
  // --vmnet-mode, corresponds to vmnet_operation_mode_key
  operating_modes_t vmnet_mode;
  // --vmnet-interface, corresponds to vmnet_shared_interface_name_key
  char *vmnet_interface;
  // --vmnet-gateway, corresponds to vmnet_start_address_key
  char *vmnet_gateway;
  // --vmnet-dhcp-end, corresponds to vmnet_end_address_key
  char *vmnet_dhcp_end;
  // --vmnet-mask, corresponds to vmnet_subnet_mask_key
  char *vmnet_mask;
  // --vmnet-interface-id, corresponds to vmnet_interface_id_key
  uuid_t vmnet_interface_id;
  // --vmnet-network-identifier, corresponds to vmnet_network_identifier_key
  uuid_t vmnet_network_identifier;
  // --vmnet-nat66-prefix, corresponds to vmnet_nat66_prefix_key
  char *vmnet_nat66_prefix;
  // -p, --pidfile; writes pidfile using permissions of socket_vmnet
  char *pidfile;
  // arg
  char *socket_path;
};

struct cli_options *cli_options_parse(int argc, char *argv[]);
void cli_options_destroy(struct cli_options *);

#endif /* SOCKET_VMNET_CLI_H */
