#ifndef CSE160_TRANSPORT_PACKET_H
#define CSE160_TRANSPORT_PACKET_H

#include "packet.h"

/*
 * Project 3 compact transport header.
 *
 * Is exactly 9 bytes, encoded explicitly in
 * msg.payload[] rather than by copying a padded C struct
 *
 * Byte 0: source port (uint8_t)
 * Byte 1: destination port (uint8_t)
 * Byte 2: flags (bit mask)
 * Bytes 3-4: seq number (uint16_t)
 * Bytes 5-6: acknowledgment number (uint16_t)
 * Byte 7: advertised receive window (uint8_t)
 * Byte 8: data length (uint8_t)
 * Bytes 9+: application data, exactly data length bytes
 *
 * Sequence numbers count stream bytes. SYN and FIN each consume one
 * sequence number. Pure ACK consumes none. Initial implementation
 * will use a documented no-wrap sequence-number range.
 */
enum {
    TP_FLAG_SYN = 0x01,
    TP_FLAG_ACK = 0x02,
    TP_FLAG_FIN = 0x04,
    TP_FLAG_DATA = 0x08,
    TP_FLAG_WINDOW_CHECK = 0x10,

    TP_OFF_SRC_PORT = 0,
    TP_OFF_DST_PORT = 1,
    TP_OFF_FLAGS = 2,
    TP_OFF_SEQ = 3,
    TP_OFF_ACK = 5,
    TP_OFF_WINDOW = 7,
    TP_OFF_LENGTH = 8,

    TP_HEADER_SIZE = 9,
    TP_MAX_DATA_SIZE = PACKET_MAX_PAYLOAD_SIZE - TP_HEADER_SIZE,

};

#endif
