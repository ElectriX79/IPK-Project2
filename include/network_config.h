#include <stdio.h>
#include <unistd.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
//
// Created by electrix on 4/16/26.
//

#ifndef IPK_PROJECT2_PROGRAM_CONFIGURATION_H_H
#define IPK_PROJECT2_PROGRAM_CONFIGURATION_H_H

#endif //IPK_PROJECT2_PROGRAM_CONFIGURATION_H_H



struct network_config {
    bool is_server;
    bool is_client;
    uint16_t port;
    struct addrinfo *addr;
    socklen_t addr_len;
    char *input_file;
    char *output_file;
    int timeout;
};

