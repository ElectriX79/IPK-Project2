//
// Created by electrix on 4/30/26.
//

#ifndef IPK_PROJECT2_READ_WRITE_ENGINE_H
#define IPK_PROJECT2_READ_WRITE_ENGINE_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

int write_to_file(FILE *out, const uint8_t *data, size_t size, long offset);
ssize_t read_from_file(FILE *in, uint8_t *buffer, size_t max_len, bool *eof);



#endif //IPK_PROJECT2_READ_WRITE_ENGINE_H