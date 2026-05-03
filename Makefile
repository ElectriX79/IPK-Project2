# Makefile for ipk-rdt — Reliable UDP File Transfer
# Author: Samuel Chovan (xchovas00)

CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -pedantic -D_GNU_SOURCE -g
LDFLAGS =

TARGET  = ipk-rdt
SRCDIR  = src
INCDIR  = include
OBJDIR  = obj

SRCS    = $(wildcard $(SRCDIR)/*.c)
OBJS    = $(patsubst $(SRCDIR)/%.c, $(OBJDIR)/%.o, $(SRCS))

.PHONY: all clean

# Default target — build the executable in the repository root
all: $(TARGET)

# Link all object files into the final executable
$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)

# Compile each .c file into a .o file in obj/
$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -I$(INCDIR) -c $< -o $@

# Create obj/ directory if it does not exist
$(OBJDIR):
	mkdir -p $(OBJDIR)

# Remove build artifacts and the executable
clean:
	rm -rf $(OBJDIR)
	rm -f $(TARGET)
