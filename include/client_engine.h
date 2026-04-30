//
// Created by electrix on 4/30/26.
//

#ifndef IPK_PROJECT2_CLIENT_ENGINE_H
#define IPK_PROJECT2_CLIENT_ENGINE_H

#include "config.h"

int client_engine(int sock_id, struct config *cfg);
int client_handshake(int sock_id);

#endif //IPK_PROJECT2_CLIENT_ENGINE_H