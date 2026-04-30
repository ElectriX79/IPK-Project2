//
// Created by electrix on 4/30/26.
//
#include "../include/checksum.h"


uint16_t compute_checksum(const void *data, long len) {
    const uint16_t *ptr = data;
    uint32_t sum = 0;

    // sčítanie 16-bit slov
    while (len > 1) {
        sum += *ptr++;
        len -= 2;
    }

    // ak ostane 1 byte
    if (len > 0) {
        sum += *(uint8_t *)ptr;
    }

    // carry wraparound
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~sum;
}