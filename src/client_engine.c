//
// Created by electrix on 4/30/26.
//

#include "../include/client_engine.h"
#include "../include/rdt_header.h"
#include "../include/read_write_engine.h"
#include <stdio.h>
#include <stdlib.h>

#define MSG_SIZE 1200;



int client_handshake(int sock_id) {

}

int client_engine(int sock_id, struct config *cfg) {
    if(sock_id == -1) {
        fprintf(stderr, "Error: Socket does not exist");
        exit(1);
    }




    return 0;
}