# Makefile for ipk-rdt — Reliable UDP File Transfer
# Author: Samuel Chovan (xchovas00)

CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -pedantic -D_GNU_SOURCE -g
LDFLAGS =

TARGET  = ipk-rdt
SRCDIR  = src
INCDIR  = include
SRCS    = $(wildcard $(SRCDIR)/*.c)

.PHONY: all clean

# Default target — compile all sources directly into the executable
all:
	$(CC) $(CFLAGS) -I$(INCDIR) $(SRCS) -o $(TARGET) $(LDFLAGS)

# Remove the executable
clean:
	rm -f $(TARGET)

NixDevShellName:
	@echo c