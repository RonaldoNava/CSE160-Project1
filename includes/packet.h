// Author: UCM ANDES Lab
//$Author: abeltran2 $
//$LastChangedBy: abeltran2 $

#ifndef PACKET_H
#define PACKET_H

#include "protocol.h"
#include "channels.h"

enum
{
	PACKET_HEADER_LENGTH = 8,
	PACKET_MAX_PAYLOAD_SIZE = 28 - PACKET_HEADER_LENGTH,
	MAX_TTL = 20
};

// add neighbor discovery header
typedef nx_struct NeighborDiscoveryHeader
{
	nx_uint8_t type;
	nx_uint16_t seq;
}
NeighborDiscoveryHeader;

// add flooding header
typedef nx_struct FloodingHeader
{
	nx_uint16_t src;	   // source node ID
	nx_uint16_t seq;	   // flood level sequence number
	nx_uint8_t TTL;		   // hops remaining, decreases after every hop
	nx_uint8_t payload[0]; // zero length array trick
}
FloodingHeader;

enum
{
	FLOODING_MAX_PAYLOAD_SIZE = PACKET_MAX_PAYLOAD_SIZE - sizeof(FloodingHeader)
};

// Link-State Advertisement header
typedef nx_struct LSAHeader
{
	nx_uint16_t seq;
	nx_uint8_t parts;	  // Index of this fragment
	nx_uint8_t numparts;  // Total fragments in this LSA
	nx_uint8_t count;	  // Number of neighbor tuples in this fragment
	nx_uint8_t tuples[0]; // Neighbor tuples follow
}
LSAHeader;

// One neighbor and its link cost
typedef nx_struct LSATuple
{
	nx_uint16_t neighbor;
	nx_uint8_t cost;
}
LSATuple;

enum
{
	LSA_MAX_TUPLES =
			(PACKET_MAX_PAYLOAD_SIZE - sizeof(LSAHeader)) /
		sizeof(LSATuple)
};

// add IP header
typedef nx_struct IPHeader
{
	nx_uint16_t src;	   // Original source node
	nx_uint16_t dest;	   // Final destination node
	nx_uint8_t protocol;   // Payload type, e.g. ping or ping reply
	nx_uint8_t TTL;		   // Remaining hops
	nx_uint8_t payload[0]; // Application data follows
}
IPHeader;

enum
{
	IP_MAX_PAYLOAD_SIZE =
			PACKET_MAX_PAYLOAD_SIZE -
		sizeof(IPHeader)
};

enum
{
	IP_PROTOCOL_PING = 0,
	IP_PROTOCOL_PING_REPLY = 1,
	IP_PROTOCOL_TCP = 2,
	IP_PROTOCOL_DV = 3,
	IP_PROTOCOL_NEIGHBOR = 4,
	IP_PROTOCOL_FLOODING = 5
};

enum
{
	FLOOD_PING = 0,
	FLOOD_PING_REPLY = 1
};

enum
{
	ND_REQUEST = 0,
	ND_REPLY = 1
};

typedef nx_struct pack
{
	nx_uint16_t dest;
	nx_uint16_t src;
	nx_uint16_t seq; // Sequence Number
	nx_uint8_t TTL;	 // Time to Live
	nx_uint8_t protocol;
	nx_uint8_t payload[PACKET_MAX_PAYLOAD_SIZE];
}
pack;

/*
 * logPack
 * 	Sends packet information to the general channel.
 * @param:
 * 		pack *input = pack to be printed.
 */
void logPack(pack *input)
{
	dbg(GENERAL_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol:%hhu  Payload: %s\n",
		input->src, input->dest, input->seq, input->TTL, input->protocol, input->payload);
}

enum
{
	AM_PACK = 6
};

#endif
