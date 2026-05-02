//
// Created by electrix on 4/30/26.
//

#include "../include/client_engine.h"
#include "../include/rdt_header.h"
#include "../include/read_write_engine.h"
#include "../include/checksum.h"
#include "../include/gbn.h"

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>
#include <netinet/in.h>

#define MSG_SIZE 1200;




int client_server_handshake(int sock_id, struct config *cfg) {
    // Header initialization for first stage of handshake
    struct rdt_header packet_hdr = {0};
    struct rdt_header packet_rcv = {0};
    const uint32_t conn_id = (uint32_t)(rand() % 10000);
    cfg->connection_id = conn_id;
    packet_hdr.connection_id = conn_id;
    packet_hdr.seq_num = 0;
    packet_hdr.ack = 0;
    packet_hdr.flags = SYN;
    packet_hdr.data_len = 0;
    packet_hdr.checksum = 0;

    // setting timeout for recv
    struct timeval tv = {0,200000};
    setsockopt(sock_id, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    time_t start = time(NULL);

    // Converting data to network byte order before computing checksum - prevention from distinguish endian system
    // on end points
    packet_hdr.connection_id = htonl(packet_hdr.connection_id);
    packet_hdr.seq_num = htonl(packet_hdr.seq_num);
    packet_hdr.ack = htonl(packet_hdr.ack);
    packet_hdr.data_len = htons(packet_hdr.data_len);

    packet_hdr.checksum = compute_checksum(&packet_hdr, sizeof(packet_hdr));

    while(1) {
        if(send(sock_id, &packet_hdr, sizeof(packet_hdr), 0) < 0) {
            perror("send SYN");
            return -1;
        }

        int n = recv(sock_id, &packet_rcv, sizeof(packet_rcv), 0);
        if(n < 0) {
            if(errno != EWOULDBLOCK && errno != EAGAIN) {
                perror("recv");
                return -1;
            }
            continue;
        }

        uint16_t rcv_checksum = packet_rcv.checksum;
        packet_rcv.checksum = 0;




        if(compute_checksum(&packet_rcv, sizeof(packet_rcv)) != rcv_checksum) {
            continue;
        }

        packet_rcv.connection_id = ntohl(packet_rcv.connection_id);


        if(packet_rcv.flags == (SYN | ACK) && conn_id == packet_rcv.connection_id) {
            struct rdt_header ack = {0};

            ack.connection_id = htonl(conn_id);
            ack.seq_num = htonl(1);
            ack.ack = htonl(packet_rcv.seq_num + 1 );
            ack.checksum = 0;
            ack.data_len = 0;
            ack.flags = ACK;

            ack.checksum = compute_checksum(&ack, sizeof(ack));

            if(send(sock_id, &ack, sizeof(ack), 0 ) < 0 ) {
                perror("send ACK\n");
            }
            return 0;
        }

        if( time(NULL) - start >= cfg->timeout) {
            fprintf(stderr, "Handshake timeout\n");
            return -1;
        }

    }
}

int client_engine(int sock_id, struct config *cfg) {
    if(sock_id == -1) {
        fprintf(stderr, "Error: Socket does not exist\n");
        return -1;
    }

    if(client_server_handshake(sock_id, cfg) != 0) {
        fprintf(stderr, "Error: Handshake failed\n");
        return -1;
    }

    struct window window;
    window_init(&window, cfg);



    while(1) {
        if(window.done == true && window.base == window.next_seq) {
            terminate_connection(sock_id, cfg);
            return 0;
        }
        if(window.next_seq < window.base + WINDOW_SIZE) {
            if(window_send(sock_id, &window, cfg) != 0) {
                exit(1);
            }
        }
        if(window_receive_ack(sock_id, &window, cfg) == 0) {
            window_retransmit(sock_id, &window, cfg);
        }


    }












    return 0;
}