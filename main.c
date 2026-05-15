#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <pcap.h>
#include <stdio.h>
#include <string.h>

static void packet_handler(u_char *user, const struct pcap_pkthdr *header, const u_char *data) {
    const char *target = "AT+BVRA=";
    unsigned int tlen = 8;

    if (header->caplen < tlen) return;

    for (unsigned int i = 0; i <= header->caplen - tlen; i++) {
        if (memcmp(data + i, target, tlen) == 0 && i + tlen < header->caplen) {
            char val = (char)data[i + tlen];
            if (val == '1')
                printf("[BUTTON] Voice assistant: ON\n");
            else if (val == '0')
                printf("[BUTTON] Voice assistant: OFF\n");
            fflush(stdout);
            break;
        }
    }
}

int main(int argc, char *argv[]) {
    char errbuf[PCAP_ERRBUF_SIZE];

    if (argc < 2) {
        pcap_if_t *devs, *d;
        int i = 1;
        if (pcap_findalldevs(&devs, errbuf) < 0) {
            fprintf(stderr, "Error: %s\n", errbuf);
            return 1;
        }
        printf("Available interfaces:\n\n");
        for (d = devs; d; d = d->next) {
            printf("  [%d] %s\n", i++, d->name);
            if (d->description)
                printf("      %s\n\n", d->description);
        }
        pcap_freealldevs(devs);
        printf("Usage: nothing_detector.exe <interface_name>\n");
        printf("Try:   nothing_detector.exe \"\\\\.\\USBPcap1\"\n");
        return 0;
    }

    pcap_t *handle = pcap_open(argv[1], 65536, 1, 100, NULL, errbuf);
    if (!handle) {
        fprintf(stderr, "Cannot open interface: %s\n", errbuf);
        return 1;
    }

    printf("Listening for Nothing Headphones button presses...\n");
    printf("Press Ctrl+C to stop.\n\n");
    pcap_loop(handle, 0, packet_handler, NULL);
    pcap_close(handle);
    return 0;
}
