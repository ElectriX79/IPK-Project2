#include <stdint.h>

//
// Created by electrix on 4/29/26.
//

#ifndef IPK_PROJECT2_RDT_HEADER_H
#define IPK_PROJECT2_RDT_HEADER_H

// Flag bit masks (can be combined using bitwise OR)
#define SYN  0x01  // connection start (synchronize)
#define ACK  0x02  // acknowledgement
#define FIN  0x04  // connection termination
#define DATA 0x08  // data packet (optional, can be inferred from data_len)

// Maximum payload size (fits into UDP 1200B limit with header)
#define PAYLOAD_SIZE 1180


// Protocol header (metadata for each packet)
struct rdt_header {
    uint32_t connection_id; // identifies transfer/session
    uint32_t seq_num;       // packet offset
    uint32_t ack;           // cumulative ACK (next expected packet)
    uint32_t checksum;      // integrity check (header + data)
    uint16_t data_len;      // size of payload in bytes
    uint8_t flags;          // control flags (SYN, ACK, FIN, ...)
};


// Full packet (header + payload)
struct packet {
    struct rdt_header hdr;         // protocol header
    char payload[PAYLOAD_SIZE];    // actual data being transferred
};

#endif //IPK_PROJECT2_RDT_HEADER_H





