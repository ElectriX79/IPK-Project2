#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include "../include/network_config.h"


//
// Created by electrix on 4/16/26.
//

int socket_setup(struct network_config *cfg) {
    struct addrinfo *p;
    int sock = -1;

    for(p = cfg->addr; p != NULL; p = p->ai_next) {
        sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if(!sock) {
            continue;
        }
        if(cfg->is_server) {
            if(bind(sock, p->ai_addr,p->ai_addrlen) == 0) {
                return sock;
            }
        }
        close(sock);
        sock = -1;
    }
    fprintf(stderr, "Failed to create socket\n");
    return -1;


}

void print_help(void) {
    printf(
        "Usage:\n"
        "  Server:\n"
        "    ./ipk-rdt -s -p PORT [-a ADDRESS] [-o OUTPUT] [-w TIMEOUT] [-h | --help]\n"
        "\n"
        "  Client:\n"
        "    ./ipk-rdt -c -a HOST -p PORT [-i INPUT] [-w TIMEOUT] [-h | --help]\n"
        "\n"
        "Options:\n"
        "  -h, --help       Show this help message and exit\n"
        "  -s               Run in server mode (receive data)\n"
        "  -c               Run in client mode (send data)\n"
        "  -p PORT          UDP port number\n"
        "  -a ADDRESS       Server: local bind address (optional)\n"
        "                   Client: destination host (IPv4/IPv6 or hostname)\n"
        "  -i INPUT         Input file (client only). Use '-' or omit for stdin\n"
        "  -o OUTPUT        Output file (server only). Use '-' or omit for stdout\n"
        "  -w TIMEOUT       Timeout in seconds (default: 1)\n"
        "\n"
        "Notes:\n"
        "  - Exactly one of -s or -c must be specified\n"
        "  - All communication uses UDP\n"
        "  - Supports both IPv4 and IPv6\n"
    );
}


void argument_parser(int argc, char **argv, struct network_config *cfg) {
    int opt;

    // defaulty
    memset(cfg, 0, sizeof(*cfg));
    cfg->timeout = 1;

    char *address = NULL;
    char port_str[10] = {0};

    while ((opt = getopt(argc, argv, "sca:p:i:o:w:h")) != -1) {
        switch (opt) {
            case 's':
                cfg->is_server = true;
                break;

            case 'c':
                cfg->is_client = true;
                break;

            case 'a':
                address = optarg;
                break;

            case 'p':
                cfg->port = atoi(optarg);
                snprintf(port_str, sizeof(port_str), "%s", optarg);
                break;

            case 'i':
                cfg->input_file = optarg;
                break;

            case 'o':
                cfg->output_file = optarg;
                break;

            case 'w':
                cfg->timeout = atoi(optarg);
                break;

            case 'h':
                print_help();
                exit(0);

            default:
                fprintf(stderr, "Invalid arguments\n");
                exit(1);
        }
    }

    if (cfg->is_server == cfg->is_client) {
        fprintf(stderr, "Error: specify exactly one of -c or -s\n");
        exit(1);
    }

    if (cfg->port == 0) {
        fprintf(stderr, "Error: -p PORT is required\n");
        exit(1);
    }

    if (cfg->timeout <= 0) {
        fprintf(stderr, "Error: timeout must be > 0\n");
        exit(1);
    }

    if (cfg->is_client && address == NULL) {
        fprintf(stderr, "Error: client requires -a HOST\n");
        exit(1);
    }

    if (cfg->is_client && cfg->input_file == NULL) {
        cfg->input_file = "-";
    }

    if (cfg->is_server && cfg->output_file == NULL) {
        cfg->output_file = "-";
    }

    struct addrinfo hints, *res;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;

    if (cfg->is_server) {
        hints.ai_flags = AI_PASSIVE;
    }

    int err = getaddrinfo(
        address,
        port_str,
        &hints,
        &res
    );

    if (err != 0) {
        fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(err));
        exit(1);
    }

    // uloženie adresy
    cfg->addr = res;
}




int main(int argc, char **argv) {
    struct network_config net_cnfg;
    argument_parser(argc, argv, &net_cnfg);


}