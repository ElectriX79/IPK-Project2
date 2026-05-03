//
// Created by electrix on 4/30/26.
//

#include "../include/client_engine.h"
#include "../include/rdt_header.h"
#include "../include/read_write_engine.h"
#include "../include/checksum.h"
#include "../include/gbn.h"
#include "../include/gbn.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>
#include <netinet/in.h>

#define MSG_SIZE 1200;

int terminate_connection(int sock_id, struct config *cfg) {

    struct rdt_header fin = {0};
    struct rdt_header resp = {0};

    fin.connection_id = htonl(cfg->connection_id);
    fin.seq_num = htonl(0);
    fin.ack = htonl(0);
    fin.data_len = htons(0);
    fin.flags = FIN;
    fin.checksum = 0;

    fin.checksum = compute_checksum(&fin, sizeof(fin));

    for (int i = 0; i < 5; i++) {

        if (send(sock_id, &fin, sizeof(fin), 0) < 0) {
            perror("send FIN");
            return -1;
        }

        int n = recv(sock_id, &resp, sizeof(resp), 0);

        if (n < 0) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
                continue;
            }
            perror("recv FIN-ACK");
            return -1;
        }

        uint32_t chk = resp.checksum;
        resp.checksum = 0;

        if (compute_checksum(&resp, sizeof(resp)) != chk) {
            continue;
        }

        uint32_t conn_id = ntohl(resp.connection_id);

        if (conn_id != cfg->connection_id) {
            continue;
        }

        if ((resp.flags & (FIN | ACK)) == (FIN | ACK)) {
            return 0;
        }
    }

    fprintf(stderr, "Failed to terminate connection\n");
    return -1;
}




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
        if(time(NULL) - start >= cfg->timeout) {
            fprintf(stderr, "Handshake timeout\n");
            return -1;
        }

        if(send(sock_id, &packet_hdr, sizeof(packet_hdr), 0) < 0) {
            perror("send SYN");
            return -1;
        }

        int n = recv(sock_id, &packet_rcv, sizeof(packet_rcv), 0);

        if(n <= 0) {
            continue;
        }


        uint32_t rcv_checksum = packet_rcv.checksum;
        packet_rcv.checksum = 0;




        if(compute_checksum(&packet_rcv, sizeof(packet_rcv)) != rcv_checksum) {
            continue;
        }

        packet_rcv.connection_id = ntohl(packet_rcv.connection_id);
        packet_rcv.ack = ntohl(packet_rcv.ack);

        if(packet_rcv.flags == (SYN | ACK) && conn_id == packet_rcv.connection_id) {
            return 0;
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

    struct timeval tv_data = {0, 100000};  // 100ms
    setsockopt(sock_id, SOL_SOCKET, SO_RCVTIMEO, &tv_data, sizeof(tv_data));

    struct window window;
    window_init(&window, cfg);

    time_t last_progress = time(NULL);

    while(1) {

        if (time(NULL) - last_progress > cfg->timeout) {
            fprintf(stderr, "Global timeout reached\n");
            window_cleanup(sock_id, &window);
            return -1;
        }

        if(window.done == true && window.base == window.next_seq) {
            terminate_connection(sock_id, cfg);
            return 0;
        }
        if(window.next_seq < window.base + WINDOW_SIZE) {
            if(window_send(sock_id, &window, cfg) != 0) {
                window_cleanup(sock_id,&window);
                return -1;
            }
            last_progress = time(NULL);
        }
        int ret = window_receive_ack(sock_id, &window, cfg);
        if(ret == 0) {
            last_progress = time(NULL);
            continue;
        }
        else if (ret == TIMEOUT) {
            if(window_retransmit(sock_id, &window, cfg) < 0) {
                window_cleanup(sock_id, &window);
                return -1;
            }
            last_progress = time(NULL);
        }
        else if(ret == -1) {
            window_cleanup(sock_id, &window);
            return -1;
        }
    }
}