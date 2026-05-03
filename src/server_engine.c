//
// Created by electrix on 4/30/26.
//

#include "../include/server_engine.h"
#include "../include/checksum.h"
#include "../include/read_write_engine.h"
#include "../include/rdt_header.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <errno.h>

int server_engine(int sock_id, struct config *cfg) {

    if (sock_id < 0) {
        fprintf(stderr, "Invalid socket\n");
        return -1;
    }

    FILE *output = NULL;
    bool is_stdout = false;

    if (strcmp(cfg->output_file, "-") == 0) {
        output = stdout;
        is_stdout = true;
    } else {
        output = fopen(cfg->output_file, "wb");
        if (!output) {
            perror("fopen");
            return -1;
        }
    }

    uint32_t expected_seq = 0;
    bool handshake_done = false;
    uint32_t conn_id = 0;

    struct sockaddr_storage client_addr;
    socklen_t addr_len = sizeof(client_addr);

    struct packet pkt;

    while (1) {

        ssize_t n = recvfrom(sock_id,&pkt,sizeof(pkt),0,(struct sockaddr *)&client_addr,&addr_len);

        if (n < 0) {
            if (errno == EWOULDBLOCK || errno == EAGAIN) {
                continue;
            }
            perror("recvfrom");
            break;
        }

        uint32_t recv_checksum = pkt.hdr.checksum;
        pkt.hdr.checksum = 0;

        if (compute_checksum(&pkt, n) != recv_checksum) {
            continue;
        }

        uint32_t pkt_conn_id = ntohl(pkt.hdr.connection_id);
        uint32_t seq = ntohl(pkt.hdr.seq_num);
        uint16_t data_len = ntohs(pkt.hdr.data_len);

        if (pkt.hdr.flags & SYN) {

            conn_id = pkt_conn_id;
            expected_seq = 0;
            handshake_done = true;

            struct rdt_header syn_ack = {0};
            syn_ack.connection_id = htonl(conn_id);
            syn_ack.seq_num = htonl(0);
            syn_ack.ack = htonl(0);
            syn_ack.flags = SYN | ACK;
            syn_ack.data_len = 0;
            syn_ack.checksum = 0;
            syn_ack.checksum = compute_checksum(&syn_ack, sizeof(syn_ack));

            sendto(sock_id,&syn_ack,sizeof(syn_ack), 0,(struct sockaddr *)&client_addr,addr_len);

            continue;
        }

        if (!handshake_done) {
            continue;
        }
        if (pkt_conn_id != conn_id) {
            continue;
        }


        if (pkt.hdr.flags & DATA) {

            if (seq == expected_seq) {

                if (is_stdout) {
                    fwrite(pkt.payload, 1, data_len, output);
                } else {
                    write_to_file(output, (uint8_t *)pkt.payload, data_len,
                                  (long)seq  * DATA_LEN);
                }

                expected_seq++;
            }

            struct rdt_header ack = {0};
            ack.connection_id = htonl(conn_id);
            ack.ack  = htonl(expected_seq - 1);
            ack.flags = ACK;
            ack.data_len = 0;
            ack.checksum = 0;
            ack.checksum = compute_checksum(&ack, sizeof(ack));

            sendto(sock_id,&ack,sizeof(ack),0,(struct sockaddr *)&client_addr,addr_len);
        }

        if (pkt.hdr.flags & FIN) {

            struct rdt_header fin_ack = {0};
            fin_ack.connection_id = htonl(conn_id);
            fin_ack.flags = FIN | ACK;
            fin_ack.checksum = 0;
            fin_ack.checksum = compute_checksum(&fin_ack, sizeof(fin_ack));

            sendto(sock_id,&fin_ack,sizeof(fin_ack),0,(struct sockaddr *)&client_addr,addr_len);
            break;
        }
    }

    if (output && !is_stdout) {
        fclose(output);
    }
    return 0;
}