#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <unistd.h>
#include <netdb.h>
#include "../include/arg_parser.h"
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
    struct config net_cfg;
    argument_parser(argc, argv, &net_cfg);






}