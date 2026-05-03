#!/usr/bin/env python3
"""
UDP proxy simulujúci sieťové podmienky:
- packet loss
- packet duplication
- packet reordering
- delay/jitter

Použitie:
  python3 udp_proxy.py --listen 6000 --forward 5000 \
    --loss 10 --dup 5 --reorder 10 --delay 50 --jitter 20
"""

import socket
import threading
import random
import time
import argparse
import sys

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--listen',  type=int, required=True,  help='Port na ktorom proxy počúva (klient sa pripojí sem)')
    p.add_argument('--forward', type=int, required=True,  help='Port na ktorý proxy preposiela (server počúva tu)')
    p.add_argument('--loss',    type=float, default=0,    help='Pravdepodobnosť straty paketu v %% (0-100)')
    p.add_argument('--dup',     type=float, default=0,    help='Pravdepodobnosť duplikácie paketu v %% (0-100)')
    p.add_argument('--reorder', type=float, default=0,    help='Pravdepodobnosť preusporiadania paketu v %% (0-100)')
    p.add_argument('--delay',   type=float, default=0,    help='Základné oneskorenie v ms')
    p.add_argument('--jitter',  type=float, default=0,    help='Náhodné jitter v ms')
    p.add_argument('--seed',    type=int,   default=42,   help='Random seed pre reprodukovateľnosť')
    return p.parse_args()

class UDPProxy:
    def __init__(self, args):
        self.listen_port  = args.listen
        self.forward_port = args.forward
        self.loss_pct     = args.loss / 100.0
        self.dup_pct      = args.dup  / 100.0
        self.reorder_pct  = args.reorder / 100.0
        self.delay_ms     = args.delay
        self.jitter_ms    = args.jitter
        self.rng          = random.Random(args.seed)

        self.client_addr  = None
        self.lock         = threading.Lock()
        self.pending      = []   # pakety čakajúce na reorder

        self.sock_listen  = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock_listen.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock_listen.bind(('127.0.0.1', self.listen_port))

        self.sock_forward = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.server_addr  = ('127.0.0.1', self.forward_port)

        self.stats = {'c2s': 0, 'c2s_lost': 0, 'c2s_dup': 0,
                      's2c': 0, 's2c_lost': 0, 's2c_dup': 0}

    def should_drop(self):
        return self.rng.random() < self.loss_pct

    def should_dup(self):
        return self.rng.random() < self.dup_pct

    def should_reorder(self):
        return self.rng.random() < self.reorder_pct

    def compute_delay(self):
        base   = self.delay_ms
        jitter = self.rng.uniform(-self.jitter_ms, self.jitter_ms) if self.jitter_ms > 0 else 0
        return max(0, (base + jitter)) / 1000.0

    def send_after_delay(self, sock, data, addr, delay):
        if delay > 0:
            def _send():
                time.sleep(delay)
                try:
                    sock.sendto(data, addr)
                except:
                    pass
            threading.Thread(target=_send, daemon=True).start()
        else:
            try:
                sock.sendto(data, addr)
            except:
                pass

    def forward_packet(self, data, dst_sock, dst_addr, direction):
        delay = self.compute_delay()

        # reorder — ulož paket, pošli nabudúce (swap s pending)
        if self.should_reorder() and self.pending:
            with self.lock:
                old_data, old_sock, old_addr = self.pending.pop(0)
            self.send_after_delay(dst_sock, data, dst_addr, delay)
            # pošli starý paket neskôr
            self.send_after_delay(old_sock, old_data, old_addr, delay + self.compute_delay())
            return
        elif self.should_reorder():
            with self.lock:
                self.pending.append((data, dst_sock, dst_addr))
            return

        # drop
        if self.should_drop():
            self.stats[direction + '_lost'] += 1
            return

        # send
        self.stats[direction] += 1
        self.send_after_delay(dst_sock, data, dst_addr, delay)

        # duplicate
        if self.should_dup():
            self.stats[direction + '_dup'] += 1
            extra_delay = delay + self.rng.uniform(0.005, 0.05)
            self.send_after_delay(dst_sock, data, dst_addr, extra_delay)

    def client_to_server(self):
        """Prijíma od klienta, preposiela na server."""
        while True:
            try:
                data, addr = self.sock_listen.recvfrom(4096)
                with self.lock:
                    self.client_addr = addr
                self.forward_packet(data, self.sock_forward, self.server_addr, 'c2s')
            except Exception as e:
                print(f"[proxy c2s] {e}", file=sys.stderr)

    def server_to_client(self):
        """Prijíma od servera, preposiela na klienta."""
        while True:
            try:
                data, _ = self.sock_forward.recvfrom(4096)
                with self.lock:
                    ca = self.client_addr
                if ca:
                    self.forward_packet(data, self.sock_listen, ca, 's2c')
            except Exception as e:
                print(f"[proxy s2c] {e}", file=sys.stderr)

    def run(self):
        t1 = threading.Thread(target=self.client_to_server, daemon=True)
        t2 = threading.Thread(target=self.server_to_client, daemon=True)
        t1.start()
        t2.start()
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print(f"\n[proxy stats] c2s={self.stats['c2s']} lost={self.stats['c2s_lost']} dup={self.stats['c2s_dup']}", file=sys.stderr)
            print(f"[proxy stats] s2c={self.stats['s2c']} lost={self.stats['s2c_lost']} dup={self.stats['s2c_dup']}", file=sys.stderr)

if __name__ == '__main__':
    args = parse_args()
    proxy = UDPProxy(args)
    proxy.run()
