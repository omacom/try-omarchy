#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <arpa/inet.h>
#include <getopt.h>

#include <Availability.h>
#include <uuid/uuid.h>

#include "cli.h"
#include "log.h"

#ifndef VERSION
#define VERSION "UNKNOWN"
#endif

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101500
#error "Requires macOS 10.15 or later"
#endif

#define CLI_DEFAULT_SOCKET_GROUP "staff"

static void print_usage(const char *argv0) {
  printf("Usage: %s [OPTION]... SOCKET\n", argv0);
  printf("vmnet.framework support for rootless QEMU.\n");
  printf("socket_vmnet does not require QEMU to run as the root user, but "
         "socket_vmnet itself has to run as the root, in most cases.\n");
  printf("\n");
  printf("--socket-group=GROUP                socket group name (default: "
         "\"" CLI_DEFAULT_SOCKET_GROUP "\")\n");
  printf("--vmnet-mode=(host|shared|bridged)  vmnet mode (default: \"shared\")\n");
  printf("--vmnet-interface=INTERFACE         interface used for "
         "--vmnet=bridged, e.g., \"en0\"\n");
  printf("--vmnet-gateway=IP                  gateway used for "
         "--vmnet=(host|shared), e.g., \"192.168.105.1\" (default: decided by "
         "macOS)\n");
  printf("                                    the next IP (e.g., "
         "\"192.168.105.2\") is used as the first DHCP address\n");
  printf("--vmnet-dhcp-end=IP                 end of the DHCP range (default: "
         "XXX.XXX.XXX.254)\n");
  printf("                                    requires --vmnet-gateway to be "
         "specified\n");
  printf("--vmnet-mask=MASK                   subnet mask (default: "
         "\"255.255.255.0\")\n");
  printf("                                    requires --vmnet-gateway to be "
         "specified\n");
  printf("--vmnet-interface-id=UUID           vmnet interface ID (default: "
         "random)\n");
  printf(
      "--vmnet-network-identifier=UUID     The identifier(uuid) to uniquely identify the network. "
      "\n"
      "                                    This property is only applicable to a vmnet_interface\n"
      "                                    in VMNET_HOST_MODE.\n"
      "                                    If this property is set, the vmnet_interface is added "
      "to \n"
      "                                    an isolated network with the specified\n"
      "                                    identifier. No DHCP service is provided on this "
      "network.\n");
  printf("--vmnet-nat66-prefix=PREFIX::       The IPv6 prefix to use with "
         "shared mode.\n");
  printf("                                    The prefix must be a ULA i.e. "
         "start with fd00::/8.\n");
  printf("                                    (default: random)\n");
  printf("-p, --pidfile=PIDFILE               save pid to PIDFILE\n");
  printf("-h, --help                          display this help and exit\n");
  printf("-v, --version                       display version information and "
         "exit\n");
  printf("\n");
  printf("version: " VERSION "\n");
}

static void print_version(void) { puts(VERSION); }

enum {
  CLI_OPT_SOCKET_GROUP = CHAR_MAX + 1,
  CLI_OPT_VMNET_MODE,
  CLI_OPT_VMNET_INTERFACE,
  CLI_OPT_VMNET_GATEWAY,
  CLI_OPT_VMNET_DHCP_END,
  CLI_OPT_VMNET_MASK,
  CLI_OPT_VMNET_INTERFACE_ID,
  CLI_OPT_VMNET_NAT66_PREFIX,
  CLI_OPT_VMNET_NETWORK_IDENTIFIER,
};

struct cli_options *cli_options_parse(int argc, char *argv[]) {
  struct cli_options *res = calloc(1, sizeof(*res));
  if (res == NULL) {
    ERRORN("calloc");
    exit(EXIT_FAILURE);
  }

  const struct option longopts[] = {
      {"socket-group",             required_argument, NULL, CLI_OPT_SOCKET_GROUP            },
      {"vmnet-mode",               required_argument, NULL, CLI_OPT_VMNET_MODE              },
      {"vmnet-interface",          required_argument, NULL, CLI_OPT_VMNET_INTERFACE         },
      {"vmnet-gateway",            required_argument, NULL, CLI_OPT_VMNET_GATEWAY           },
      {"vmnet-dhcp-end",           required_argument, NULL, CLI_OPT_VMNET_DHCP_END          },
      {"vmnet-mask",               required_argument, NULL, CLI_OPT_VMNET_MASK              },
      {"vmnet-interface-id",       required_argument, NULL, CLI_OPT_VMNET_INTERFACE_ID      },
      {"vmnet-nat66-prefix",       required_argument, NULL, CLI_OPT_VMNET_NAT66_PREFIX      },
      {"vmnet-network-identifier", required_argument, NULL, CLI_OPT_VMNET_NETWORK_IDENTIFIER},
      {"pidfile",                  required_argument, NULL, 'p'                             },
      {"help",                     no_argument,       NULL, 'h'                             },
      {"version",                  no_argument,       NULL, 'v'                             },
      {0,                          0,                 0,    0                               },
  };
  int opt = 0;
  while ((opt = getopt_long(argc, argv, "hvp:", longopts, NULL)) != -1) {
    switch (opt) {
    case CLI_OPT_SOCKET_GROUP:
      res->socket_group = strdup(optarg);
      break;
    case CLI_OPT_VMNET_MODE:
      if (strcmp(optarg, "host") == 0) {
        res->vmnet_mode = VMNET_HOST_MODE;
      } else if (strcmp(optarg, "shared") == 0) {
        res->vmnet_mode = VMNET_SHARED_MODE;
      } else if (strcmp(optarg, "bridged") == 0) {
        res->vmnet_mode = VMNET_BRIDGED_MODE;
      } else {
        ERRORF("Unknown vmnet mode \"%s\"", optarg);
        goto error;
      }
      break;
    case CLI_OPT_VMNET_INTERFACE:
      res->vmnet_interface = strdup(optarg);
      break;
    case CLI_OPT_VMNET_GATEWAY:
      res->vmnet_gateway = strdup(optarg);
      break;
    case CLI_OPT_VMNET_DHCP_END:
      res->vmnet_dhcp_end = strdup(optarg);
      break;
    case CLI_OPT_VMNET_MASK:
      res->vmnet_mask = strdup(optarg);
      break;
    case CLI_OPT_VMNET_INTERFACE_ID:
      if (uuid_parse(optarg, res->vmnet_interface_id) < 0) {
        ERRORF("Failed to parse UUID \"%s\"", optarg);
        goto error;
      }
      break;
    case CLI_OPT_VMNET_NAT66_PREFIX:
      res->vmnet_nat66_prefix = strdup(optarg);
      break;
    case CLI_OPT_VMNET_NETWORK_IDENTIFIER:
      if (uuid_parse(optarg, res->vmnet_network_identifier) < 0) {
        ERRORF("Failed to parse network identifier UUID \"%s\"", optarg);
        goto error;
      }
      break;
    case 'p':
      res->pidfile = strdup(optarg);
      break;
    case 'h':
      print_usage(argv[0]);
      exit(EXIT_SUCCESS);
      break;
    case 'v':
      print_version();
      exit(EXIT_SUCCESS);
      break;
    default:
      goto error;
      break;
    }
  }
  if (argc - optind != 1) {
    goto error;
  }
  res->socket_path = strdup(argv[optind]);

  /* fill default */
  if (res->socket_group == NULL)
    res->socket_group = strdup(CLI_DEFAULT_SOCKET_GROUP); /* use strdup to make it freeable */
  if (res->vmnet_mode == 0)
    res->vmnet_mode = VMNET_SHARED_MODE;
  if (res->vmnet_gateway != NULL && res->vmnet_dhcp_end == NULL) {
    /* Set default vmnet_dhcp_end to XXX.XXX.XXX.254 (only when --vmnet-gateway
     * is specified) */
    struct in_addr sin;
    if (!inet_aton(res->vmnet_gateway, &sin)) {
      ERRORN("inet_aton(res->vmnet_gateway)");
      goto error;
    }
    uint32_t h = ntohl(sin.s_addr);
    h &= 0xFFFFFF00;
    h |= 0x000000FE;
    sin.s_addr = htonl(h);
    const char *end_static = inet_ntoa(sin); /* static storage, do not free */
    if (end_static == NULL) {
      ERRORN("inet_ntoa");
      goto error;
    }
    res->vmnet_dhcp_end = strdup(end_static);
  }
  if (res->vmnet_gateway != NULL && res->vmnet_mask == NULL)
    res->vmnet_mask = strdup("255.255.255.0"); /* use strdup to make it freeable */
  if (uuid_is_null(res->vmnet_interface_id)) {
    uuid_generate_random(res->vmnet_interface_id);
  }

  /* validate */
  if (res->vmnet_mode == VMNET_BRIDGED_MODE && res->vmnet_interface == NULL) {
    ERROR("vmnet mode \"bridged\" require --vmnet-interface to be specified");
    goto error;
  }
  if (res->vmnet_gateway == NULL) {
    if (res->vmnet_mode != VMNET_BRIDGED_MODE && res->vmnet_mode != VMNET_HOST_MODE) {
      WARN("--vmnet-gateway=IP should be explicitly specified to "
           "avoid conflicting with other applications");
    }
    if (res->vmnet_dhcp_end != NULL) {
      ERROR("--vmnet-dhcp-end=IP requires --vmnet-gateway=IP");
      goto error;
    }
    if (res->vmnet_mask != NULL) {
      ERROR("--vmnet-mask=MASK requires --vmnet-gateway=IP");
      goto error;
    }
  } else {
    if (res->vmnet_mode == VMNET_BRIDGED_MODE) {
      ERROR("vmnet mode \"bridged\" conflicts with --vmnet-gateway");
      goto error;
    }
    struct in_addr dummy;
    if (!inet_aton(res->vmnet_gateway, &dummy)) {
      ERRORF("invalid address \"%s\" was specified for --vmnet-gateway", res->vmnet_gateway);
      goto error;
    }
  }
  return res;
error:
  print_usage(argv[0]);
  exit(EXIT_FAILURE);
}

void cli_options_destroy(struct cli_options *x) {
  if (x == NULL)
    return;
  free(x->socket_group);
  free(x->socket_path);
  free(x->vmnet_interface);
  free(x->vmnet_gateway);
  free(x->vmnet_dhcp_end);
  free(x->vmnet_mask);
  free(x->vmnet_nat66_prefix);
  free(x->pidfile);
  free(x);
}
