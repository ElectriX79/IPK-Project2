//
// Created by electrix on 4/30/26.
//
#include "../include/checksum.h"


/**
* @brief Computes checksum over packet data (header + payload).
*
* The checksum is calculated using a simple 16-bit one's complement algorithm:
*  - Data is divided into 16-bit words
*  - All words are summed using one's complement addition
*  - The final result is bitwise inverted
*/

uint16_t compute_checksum(const void *data, long len) {
    const uint16_t *ptr = data;
    uint32_t sum = 0;

    while (len > 1) {
        sum += *ptr++;
        len -= 2;
    }

    if (len > 0) {
        sum += *(uint8_t *)ptr;
    }

    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~sum;
}