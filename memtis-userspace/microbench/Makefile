CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS ?= -lpthread

BINS = pchase stream

all: $(BINS)

pchase: pchase.c
	$(CC) $(CFLAGS) -o $@ $<

stream: stream.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(BINS)

.PHONY: all clean
