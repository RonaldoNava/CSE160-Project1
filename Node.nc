/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include <string.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/socket.h"

module Node{uses interface Boot;

uses interface SplitControl as AMControl;
uses interface Receive;
uses interface AMPacket;

uses interface SimpleSend as Sender;

uses interface CommandHandler;
uses interface NDiscovery; // added for Neighbor Discovery
uses interface Flooding;   // added for Flooding
// uses interface LinkState;
uses interface DistanceVector;
uses interface IP;
uses interface Transport;
uses interface Timer<TMilli> as testTimer;
}

implementation
{
   typedef struct {
      bool used, producer, ready;
      uint16_t target, accepted, acked, consumed, mismatches;

      //used for the zero-window test
      bool pauseReads;
      uint32_t readAfter;
   } TestConnection;
   TestConnection testConnections[MAX_NUM_OF_SOCKETS + 1];
   
   pack sendPackage;

   // Prototypes
   void makePack(pack * Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   event void Boot.booted()
   {
      call AMControl.start();
      call NDiscovery.start(); // start discovery/timing after boot
      call Flooding.start();   // start Flooding
      // call LinkState.start(); start link state routing
      call DistanceVector.start(); // start distance vector routing
      call Transport.start();
      call testTimer.startPeriodic(200);

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err)
   {
      if (err == SUCCESS)
      {
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }
      else
      {
         // Retry until successful
         call AMControl.start();
      }
   }

   event void Flooding.received(pack msg, uint16_t source)
   {
      // Link-State handles LSA packets, not Node
      if (msg.payload[0] == FLOOD_LSA)
      {
         return;
      }

      // Not addressed to us -- FloodingP has already forwarded it on.
      if (msg.dest != TOS_NODE_ID)
      {
         return;
      }

      if (msg.payload[0] == FLOOD_PING)
      {
         uint8_t replyPayload[FLOODING_MAX_PAYLOAD_SIZE];

         dbg(FLOODING_CHANNEL, "Node %d: ping from %d received: %s\n", TOS_NODE_ID, msg.src, &msg.payload[1]);

         replyPayload[0] = FLOOD_PING_REPLY;
         memcpy(&replyPayload[1], &msg.payload[1], FLOODING_MAX_PAYLOAD_SIZE - 1);

         makePack(&sendPackage, TOS_NODE_ID, msg.src, MAX_TTL, PROTOCOL_FLOODING, 0, replyPayload, FLOODING_MAX_PAYLOAD_SIZE);
         call Flooding.flood(sendPackage);
      }
      else if (msg.payload[0] == FLOOD_PING_REPLY)
      {
         dbg(FLOODING_CHANNEL, "Ping Reply: src=%d, dest=%d, seq=%d, TTL=%d, protocol=%d, payload=%s\n", msg.src, msg.dest, msg.seq, msg.TTL, msg.protocol, &msg.payload[1]);
      }
   }

   event void AMControl.stopDone(error_t err) {}

   event void IP.received(pack msg)
   {
      if (msg.protocol == PROTOCOL_PING)
      {
         dbg(ROUTING_CHANNEL, "Node %d: Received IP ping from %d\n",
             TOS_NODE_ID, msg.src);
         call IP.send(msg.src, PROTOCOL_PINGREPLY, msg.payload, PACKET_MAX_PAYLOAD_SIZE);
      }
      else if (msg.protocol == PROTOCOL_PINGREPLY)
      {
         dbg(ROUTING_CHANNEL, "Node %d: Received IP PingReply from %d, payload %s\n",
             TOS_NODE_ID, msg.src, msg.payload);

         dbg("Project3TGen", "t=%lu node=%u PING_REPLY from=%u\n", (unsigned long)call testTimer.getNow(),
            TOS_NODE_ID, msg.src);
      }
   }

   event message_t *Receive.receive(message_t * msg, void *payload, uint8_t len)
   {

      dbg(GENERAL_CHANNEL, "Packet Received\n");

      if (len == sizeof(pack))
      {
         pack *myMsg = (pack *)payload;
         // check whether this is a neighbor-discovery packet.
         if (myMsg->protocol == PROTOCOL_NEIGHBOR)
         {
            // dbg(NEIGHBOR_CHANNEL, "Node %d received discovery from node %d\n", TOS_NODE_ID, myMsg->src);
            call NDiscovery.receive(*myMsg, myMsg->src);

            return msg;
         }
         if (myMsg->protocol == PROTOCOL_DV)
         {
            call DistanceVector.receive(*myMsg, call AMPacket.source(msg));
            return msg;
         }
         if (myMsg->protocol == PROTOCOL_FLOODING)
         {
            call Flooding.receive(*myMsg, call AMPacket.source(msg));
            return msg;
         }
         if (myMsg->protocol == PROTOCOL_IP ||
             myMsg->protocol == PROTOCOL_PING ||
             myMsg->protocol == PROTOCOL_PINGREPLY ||
             myMsg->protocol == PROTOCOL_TCP)
         {
            call IP.receive(*myMsg);
            return msg;
         }

         dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);

      return msg;
   }

   event void CommandHandler.ping(uint16_t destination, uint8_t *payload)
   {
      dbg(GENERAL_CHANNEL, "Node %d: Sending IP ping to %d\n",
          TOS_NODE_ID, destination);

      call IP.send(destination, PROTOCOL_PING, payload, PACKET_MAX_PAYLOAD_SIZE);
   }

   event void NDiscovery.neighborChanged() {}

   event void CommandHandler.printNeighbors()
   {
      call NDiscovery.printNeighbors();
   }

   event void CommandHandler.printRouteTable()
   {
      call DistanceVector.printRoutingTable();
   }
   event void DistanceVector.routeChanged() {}

   event void CommandHandler.printLinkState() {}

   event void CommandHandler.printDistanceVector() {}

   event void CommandHandler.setTestServer(uint8_t port) {
      socket_t fd = call Transport.socket();
      socket_addr_t local;
      local.addr=TOS_NODE_ID; local.port=port;
      if(!fd || call Transport.bind(fd,&local)!=SUCCESS || call Transport.listen(fd)!=SUCCESS) {
         if(fd) call Transport.release(fd);
         dbg("Project3TGen","t=%lu node=%u SERVER_FAIL port=%u\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID,port);
      }
      else {
         //only pause reads when testing port 21
         testConnections[fd].pauseReads = (port == 21);
      }
   }

   event void CommandHandler.setTestClient(uint16_t server, uint8_t srcPort, uint8_t destPort, uint16_t total) {
      socket_t fd=call Transport.socket();
      socket_addr_t local, remote;
      local.addr=TOS_NODE_ID; local.port=srcPort; remote.addr=server; remote.port=destPort;
      if(!fd || !total || total>60000U) {
         if(fd) call Transport.release(fd);
         dbg("Project3TGen","t=%lu node=%u CLIENT_FAIL allocation/length\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID); return;
      }
      memset(&testConnections[fd],0,sizeof(TestConnection));
      testConnections[fd].used=TRUE; testConnections[fd].producer=TRUE; testConnections[fd].target=total;
      if(call Transport.bind(fd,&local)!=SUCCESS || call Transport.connect(fd,&remote)!=SUCCESS) {
         testConnections[fd].used=FALSE; call Transport.release(fd);
         dbg("Project3TGen","t=%lu node=%u CLIENT_FAIL bind/connect\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID);
      }
   }

   event void CommandHandler.setAppServer() {}

   event void CommandHandler.setAppClient() {}

   void makePack(pack * Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t *payload, uint8_t length)
   {
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

    // Project 3 test application, separate from the transport engine.

   bool validTestFd(socket_t fd) { return fd > 0 && fd <= MAX_NUM_OF_SOCKETS; }


   event void CommandHandler.clientClose(uint16_t server,uint8_t srcPort,uint8_t destPort) {
      socket_t fd=call Transport.lookup(server,srcPort,destPort);
      if(validTestFd(fd) && testConnections[fd].used && testConnections[fd].accepted==testConnections[fd].target) {
         if(call Transport.close(fd)==SUCCESS) {
            dbg("Project3TGen","t=%lu node=%u fd=%u CLOSE_REQUEST\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID,fd); return;
         }
      }
      dbg("Project3TGen","t=%lu node=%u CLOSE_FAIL not ready\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID);
   }


   event void CommandHandler.testDropData() {
      call Transport.dropNextData();
   }

   event void Transport.connectDone(socket_t fd,error_t result) {
      if(validTestFd(fd) && testConnections[fd].used) testConnections[fd].ready=(result==SUCCESS);
   }
   
   event void Transport.accepted(socket_t listener, socket_t connection) {
      bool pause = validTestFd(listener) &&
                  testConnections[listener].pauseReads;

      if (!validTestFd(connection))
         return;

      memset(&testConnections[connection], 0, sizeof(TestConnection));

      testConnections[connection].used = TRUE;
      testConnections[connection].ready = TRUE;

      //pause reading for 25 seconds during the zero-window test
      if (pause) {
         testConnections[connection].readAfter =
               call testTimer.getNow() + 25000UL;

         dbg("Project3TGen",
               "t=%lu node=%u fd=%u TEST_READ_PAUSE until=%lu\n",
               (unsigned long)call testTimer.getNow(),
               TOS_NODE_ID,
               connection,
               (unsigned long)testConnections[connection].readAfter);
      }
   }

   event void Transport.acknowledged(socket_t fd,uint16_t count) {
      if(!validTestFd(fd) || !testConnections[fd].used) return;
      testConnections[fd].acked+=count;
      dbg("Project3TGen","t=%lu node=%u fd=%u ACKED total=%u\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID,fd,testConnections[fd].acked);
   }

   event void Transport.closed(socket_t fd,error_t result) {
      TestConnection *c;
      if(!validTestFd(fd) || !testConnections[fd].used) return;
      c=&testConnections[fd];
      dbg("Project3TGen","t=%lu node=%u fd=%u APP_FINAL result=%s accepted=%u acked=%u consumed=%u mismatches=%u\n",
          (unsigned long)call testTimer.getNow(),TOS_NODE_ID,fd,result==SUCCESS?"OK":"FAIL",c->accepted,c->acked,c->consumed,c->mismatches);
      c->used=FALSE;
   }

   event void testTimer.fired() {
      socket_t fd; uint8_t bytes[16]; uint16_t n,i,remaining; TestConnection *c;
      for(fd=1;fd<=MAX_NUM_OF_SOCKETS;fd++) {
         c = &testConnections[fd];
         if(!c->used || !c->ready)
            continue;
         if(c->producer && c->accepted<c->target) {
            remaining=c->target-c->accepted;
            n=remaining>sizeof(bytes)?sizeof(bytes):remaining;
            for(i=0;i<n;i++) bytes[i]=(uint8_t)(c->accepted+i);
            n=call Transport.write(fd,bytes,n); c->accepted+=n;
            if(n) dbg("Project3TGen","t=%lu node=%u fd=%u ACCEPTED total=%u\n",(unsigned long)call testTimer.getNow(),TOS_NODE_ID,fd,c->accepted);
         }
         //wait before reading during the zero-window test
         if (!c->producer && c->readAfter != 0) {

            if ((int32_t)(call testTimer.getNow() - c->readAfter) < 0)
               continue;

            dbg("Project3TGen",
               "t=%lu node=%u fd=%u TEST_READ_RESUME\n",
               (unsigned long)call testTimer.getNow(),
               TOS_NODE_ID, fd);

            c->readAfter = 0;
         }

         n = call Transport.read(fd, bytes, sizeof(bytes));

         if(n) {
            for(i=0;i<n;i++)
             if(bytes[i]!=(uint8_t)(c->consumed+i)) c->mismatches++;
            c->consumed+=n;
            dbg("Project3TGen","t=%lu node=%u fd=%u CONSUMED chunk=%u total=%u mismatches=%u\n",
                (unsigned long)call testTimer.getNow(),TOS_NODE_ID,fd,n,c->consumed,c->mismatches);
         }
      }
   }
}
