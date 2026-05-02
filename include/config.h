#include <stdbool.h>

//
// Created by electrix on 4/16/26.
//

#ifndef IPK_PROJECT2_PROGRAM_CONFIGURATION_H_H
#define IPK_PROJECT2_PROGRAM_CONFIGURATION_H_H
#include <stdint.h>
#include <sys/socket.h>


struct config {
    bool is_server;
    bool is_client;
    uint16_t port;
    struct addrinfo *addr;
    socklen_t addr_len;
    char *input_file;
    char *output_file;
    int timeout;
    long connection_id;
};

#endif //IPK_PROJECT2_PROGRAM_CONFIGURATION_H_H





