#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>
#include <netdb.h>
#include "../include/arg_parser.h"
#include "../include/server_engine.h"
#include "../include/client_engine.h"
#include "../include/rdt_header.h"
#include "../include/read_write_engine.h"


//
// Created by electrix on 4/16/26.
//


int socket_setup(struct config *cfg) {
    struct addrinfo *p;
    int sock = -1;

    // Server: skús najprv IPv6 (dual-stack pokryje aj IPv4)
    // Klient: iteruj normálne
    for (int pass = 0; pass < 2; pass++) {
        for (p = cfg->addr; p != NULL; p = p->ai_next) {

            if (cfg->is_server) {
                // pass 0 = chceme IPv6, pass 1 = IPv4 fallback
                if (pass == 0 && p->ai_family != AF_INET6) continue;
                if (pass == 1 && p->ai_family != AF_INET)  continue;
            }

            sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
            if (sock == -1) continue;

            if (cfg->is_server) {
                int opt = 1;
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

                if (p->ai_family == AF_INET6) {
                    int v6only = 0;
                    setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY,
                               &v6only, sizeof(v6only));
                }

                if (bind(sock, p->ai_addr, p->ai_addrlen) == 0) {
                    return sock;  // úspech
                }
            }

            if (cfg->is_client) {
                if (connect(sock, p->ai_addr, p->ai_addrlen) == 0) {
                    return sock;
                }
            }

            close(sock);
            sock = -1;
        }

        // Klient nepotrebuje druhý pass
        if (cfg->is_client) break;
    }

    fprintf(stderr, "Failed to create socket\n");
    return -1;
}



int main(int argc, char **argv) {

    int socket_id;
    struct config net_cfg = {0};

    argument_parser(argc, argv, &net_cfg);

    socket_id = socket_setup(&net_cfg);
    if (socket_id < 0) {
        perror("socket_setup");
        return -1;
    }

    if (net_cfg.is_server) {

        if (server_engine(socket_id, &net_cfg) != 0) {
            fprintf(stderr, "Server error\n");
        }

    } else if (net_cfg.is_client) {

        if (client_engine(socket_id, &net_cfg) != 0) {
            fprintf(stderr, "Client error\n");
        }

    } else {
        fprintf(stderr, "Error: must specify -s or -c\n");
        close(socket_id);
        return -1;
    }


    close(socket_id);
    freeaddrinfo(net_cfg.addr);

    return 0;
}






