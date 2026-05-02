cmake_minimum_required(VERSION 4.1)
project(IPK_Project2 C)

set(CMAKE_C_STANDARD 11)

add_executable(IPK_Project2
        src/main.c
        "include/config.h"
        include/rdt_header.h
        include/arg_parser.h
        src/arg_parser.c
        src/client_engine.c
        src/server_engine.c
        include/client_engine.h
        include/server_engine.h
        include/read_write_engine.h
        src/read_write_engine.c
        include/checksum.h
        src/checksum.c
        include/gbn.h
        src/gbn.c)
