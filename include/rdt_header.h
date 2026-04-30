#include <stdint.h>

//
// Created by electrix on 4/29/26.
//

#ifndef IPK_PROJECT2_RDT_HEADER_H
#define IPK_PROJECT2_RDT_HEADER_H

#define SYN 0x01
#define ACK 0x02
#define FIN 0x04

struct rdt_header {
    uint32_t connection_id;
    uint32_t seq_num;
    uint32_t ack;
    uint32_t checksum;
    uint16_t data_len;
    uint8_t flags;
};

#endif //IPK_PROJECT2_RDT_HEADER_H





