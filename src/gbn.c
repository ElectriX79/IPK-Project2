//
// Created by electrix on 5/1/26.
//

#include "../include/gbn.h"
#include "../include/read_write_engine.h"
#include "../include/checksum.h"
#include <asm-generic/errno.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <netinet/in.h>
#include <unistd.h>
void window_init(struct window *window, struct config *cfg) {
    window->base = 0;
    window->next_seq = 0;
    memset(window->packets, 0, sizeof(window->packets));

    if(strcmp(cfg->input_file, "-") == 0) {
        window->input = stdin;
    }
    else {
        window->input = fopen(cfg->input_file, "rb");
    }
}

int window_send(int sock_id, struct window *w, struct config *cfg) {

    if(w->next_seq >= w->base + WINDOW_SIZE) {
        return 0;
    }

    int index = w->next_seq % WINDOW_SIZE;
    struct rdt_header *pkt_hdr = &((w->packets[index]).hdr);
    uint8_t buffer[DATA_LEN];
    bool eof = false;
    ssize_t n = read_from_file(w->input, buffer, DATA_LEN, &eof);

    if(n < 0) {
        fprintf(stderr, "Error: read module failed");
        exit(1);
    }

    if(n == 0 && eof == true) {
        w->done = true;
        return 0;
    }
    memcpy(w->packets[index].payload, buffer, n);

    pkt_hdr->connection_id = htonl(cfg->connection_id);
    pkt_hdr->seq_num = htonl(w->next_seq);
    pkt_hdr->ack = htonl(0);
    pkt_hdr->checksum = 0;
    pkt_hdr->data_len = htons(n);
    pkt_hdr->flags = DATA;

    pkt_hdr->checksum = compute_checksum(&w->packets[index], sizeof(*pkt_hdr) + n);

    if(send(sock_id, &w->packets[index], sizeof(*pkt_hdr) + n,0) < 0) {
        fprintf(stderr, "Failed to send packet");
        return -1;
    }
    w->next_seq++;

    return 0;
}

int window_receive_ack(int sock_id, struct window *w, struct config *cfg) {
    struct rdt_header pkt_hdr = {0};
    int n = recv(sock_id, &pkt_hdr, sizeof(pkt_hdr), 0);
    if(n < 0) {
        if(errno != EWOULDBLOCK && errno != EAGAIN) {
            perror("recv");
            return -1;
        }
        return TIMEOUT;
    }

    uint32_t checksum = pkt_hdr.checksum;
    pkt_hdr.checksum = 0;

    if(compute_checksum(&pkt_hdr,sizeof(pkt_hdr)) != checksum) {
        return 1;
    }
    uint32_t conn_id = ntohl(pkt_hdr.connection_id);
    uint32_t ack = ntohl(pkt_hdr.ack);

    if(conn_id != cfg->connection_id) {
        return 1;
    }

    if(!(pkt_hdr.flags & ACK)) {
        return 1;
    }
    if(ack < w->base) {
        return 1;
    }
    if(ack>= w->next_seq) {
        return 1;
    }

    w->base = ack + 1;

    return 0;
}

int window_retransmit(int sock_id, struct window *w, struct config *cfg) {
    for(uint32_t seq = w->base; seq < w->next_seq;seq++) {
        int index = seq % WINDOW_SIZE;
        if(send(sock_id, &w->packets[index],sizeof(w->packets[index].hdr)+ntohs(w->packets[index].hdr.data_len),0) < 0) {
            perror("send retransmit");
            return -1;
        }
    }
    return 0;
}

void window_cleanup(int sock_id, struct window *w) {
    if(w != NULL) {
        if(w->input && w->input != stdin) {
            fclose(w->input);
            w->input = NULL;
        }
    }
    if(sock_id > 0) {
        close(sock_id);
    }
}