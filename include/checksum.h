//
// Created by electrix on 4/30/26.
//

#ifndef IPK_PROJECT2_CHECKSUM_H
#define IPK_PROJECT2_CHECKSUM_H

#include <stdint.h>

uint16_t compute_checksum(const void *data, long len);

#endif //IPK_PROJECT2_CHECKSUM_H