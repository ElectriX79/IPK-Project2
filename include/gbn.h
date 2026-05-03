//
// Created by electrix on 5/1/26.
//

#ifndef IPK_PROJECT2_WINDOW_H
#define IPK_PROJECT2_WINDOW_H

#include "config.h"
#include "read_write_engine.h"
#include "rdt_header.h"
#include <stdbool.h>
#define WINDOW_SIZE 10
#define TIMEOUT 2
#define DATA_LEN 1180

// Sliding window structure (used by sender)
struct window {
    struct packet packets[WINDOW_SIZE]; // buffer of unacknowledged packets
    uint32_t base;       // oldest unacknowledged sequence number
    uint32_t next_seq;   // next sequence number to send
    FILE *input;         // input stream (file or stdin)
    bool done;           // indicates end of input stream
};


// Initialize window (set base, seq numbers, input source)
void window_init(struct window *window, struct config *cfg);

// Send new packets within window (pipelined transmission)
int window_send(int sock_id, struct window *w, struct config *cfg);

// Receive and process ACKs, slide window forward
int window_receive_ack(int sock_id, struct window *w, struct config *cfg);

// Retransmit packets on timeout
int window_retransmit(int sock_id, struct window *w, struct config *cfg);

// Cleanup resources (e.g., close input stream)
void window_cleanup(int sock_id, struct window *w);



#endif //IPK_PROJECT2_WINDOW_H