cmake_minimum_required(VERSION 4.1)
project(IPK_Project2 C)

set(CMAKE_C_STANDARD 11)

add_executable(IPK_Project2
        src/main.c
        "include/network_config.h")
