//
// Created by electrix on 4/30/26.
//
#include "../include/read_write_engine.h"


int write_to_file(FILE *out, const uint8_t *data, size_t size, long offset) {
    if (out == NULL || data == NULL) {
        return 1;
    }

    if (fseek(out, offset, SEEK_SET) != 0) {
        perror("fseek");
        return 2;
    }

    size_t written = fwrite(data, 1, size, out);

    if (written != size) {
        if (ferror(out)) {
            perror("fwrite");
        }
        return 3;
    }

    return 0;
}


ssize_t read_from_file(FILE *in, uint8_t *buffer, size_t max_len, bool *eof) {
    size_t n = fread(buffer, 1, max_len, in);

    if (n < max_len) {
        if (feof(in)) {
            *eof = true;
        } else if (ferror(in)) {
            return -1;
        }
    }

    return (ssize_t)n;
}

