CC ?= cc
CLANG ?= clang
ARCH := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')
BPF_CFLAGS = -O2 -g -Wall -Wextra -target bpf -D__TARGET_ARCH_$(ARCH) -I/usr/include/$(shell gcc -dumpmachine)
.PHONY: all clean test
all: build/xdp_dns.o build/packetctl
build:
	mkdir -p build
build/xdp_dns.o: src/xdp_dns.c | build
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
build/packetctl: src/packetctl.c | build
	$(CC) -O2 -Wall -Wextra $< -o $@ $$(pkg-config --cflags --libs libbpf)
test:
	python3 -m unittest discover -s tests -v
clean:
	rm -rf build
