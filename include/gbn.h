//
// Created by electrix on 5/1/26.
//

#ifndef IPK_PROJECT2_WINDOW_H
#define IPK_PROJECT2_WINDOW_H

#include "config.h"
#include "read_write_engine.h"
#include "rdt_header.h"
#include <stdbool.h>
#define WINDOW_SIZE 50000
#define TIMEOUT 2
#define DATA_LEN 1180

struct window {
    struct packet packets[50000];
    uint32_t base;
    uint32_t next_seq;
    FILE *input;
    bool done;
};

void window_init(struct window *window, struct config *cfg);
int window_send(int sock_id, struct window *w, struct config *cfg);
int window_receive_ack(int sock_id, struct window *w, struct config *cfg);
int window_retransmit(int sock_id,struct window *w, struct config *cfg);
void window_cleanup(int sock_id, struct window *w);







#endif //IPK_PROJECT2_WINDOW_H