//
// Created by electrix on 4/30/26.
//

#include "../include/client_engine.h"
#include "../include/rdt_header.h"
#include "../include/read_write_engine.h"
#include "../include/checksum.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>
#include <netinet/in.h>

#define MSG_SIZE 1200;




int client_handshake(int sock_id) {

    struct rdt_header packet_hdr = {0};
    packet_hdr.connection_id = (uint32_t)(rand() % 10000);
    packet_hdr.seq_num = 0;
    packet_hdr.ack = 0;
    packet_hdr.flags = SYN;
    packet_hdr.data_len = 0;
    packet_hdr.checksum = 0;

    packet_hdr.connection_id = htonl(packet_hdr.connection_id);
    packet_hdr.seq_num = htonl(packet_hdr.seq_num);
    packet_hdr.ack = htonl(packet_hdr.ack);
    packet_hdr.data_len = htons(packet_hdr.data_len);

    packet_hdr.checksum = compute_checksum(&packet_hdr, sizeof(packet_hdr));




    return 0;

}

int client_engine(int sock_id, struct config *cfg) {
    if(sock_id == -1) {
        fprintf(stderr, "Error: Socket does not exist\n");
        exit(1);
    }

    if(client_handshake(sock_id) != 0) {
        fprintf(stderr, "Error: Handshake failed\n");
        exit(1);
    }





    return 0;
}