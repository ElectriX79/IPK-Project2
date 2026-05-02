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

    for(p = cfg->addr; p != NULL; p = p->ai_next) {
        sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if(sock == -1) {
            continue;
        }
        if(cfg->is_server) {
            int opt = 1;
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
            if(bind(sock, p->ai_addr,p->ai_addrlen) == 0) {
                return sock;
            }
        }
        if(cfg->is_client) {
            if(connect(sock,p->ai_addr,p->ai_addrlen) == 0) {
                return sock;
            }
        }
        close(sock);
        sock = -1;
    }
    fprintf(stderr, "Failed to create socket\n");
    return -1;


}



int main(int argc, char **argv) {

    int socket_id;
    struct config net_cfg;

    argument_parser(argc, argv, &net_cfg);

    // --- socket setup ---
    socket_id = socket_setup(&net_cfg);
    if (socket_id < 0) {
        perror("socket_setup");
        return -1;
    }

    // --- režim ---
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






