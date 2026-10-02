/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface AMPacket;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;
   uses interface NDiscovery; //added for Neighbor Discovery
   uses interface Flooding; //added for Flooding
}

implementation{
   pack sendPackage;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   event void Boot.booted(){
      call AMControl.start();
      call NDiscovery.start(); //start discovery/timing after boot
      call Flooding.start(); //start Flooding

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

      event void Flooding.received(pack msg, uint16_t source) {

      // Not addressed to us -- FloodingP has already forwarded it on.
      if (msg.dest != TOS_NODE_ID) {
         return;
      }

      if (msg.payload[0] == FLOOD_PING) {
         uint8_t replyPayload[FLOODING_MAX_PAYLOAD_SIZE];

         dbg(FLOODING_CHANNEL, "Node %d: ping from %d received: %s\n", TOS_NODE_ID, msg.src, &msg.payload[1]);

         replyPayload[0] = FLOOD_PING_REPLY;
         memcpy(&replyPayload[1], &msg.payload[1], FLOODING_MAX_PAYLOAD_SIZE - 1);

         makePack(&sendPackage, TOS_NODE_ID, msg.src, MAX_TTL, PROTOCOL_FLOODING, 0, replyPayload, FLOODING_MAX_PAYLOAD_SIZE);
         call Flooding.flood(sendPackage);
      }
      else if (msg.payload[0] == FLOOD_PING_REPLY) {
         dbg(FLOODING_CHANNEL, "Node %d: ping reply from %d received: %s\n", TOS_NODE_ID, msg.src, &msg.payload[1]);
      }
   }

   event void AMControl.stopDone(error_t err){}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
   
   dbg(GENERAL_CHANNEL, "Packet Received\n");

   if (len == sizeof(pack)) {
        pack* myMsg = (pack*) payload;
      //check whether this is a neighbor-discovery packet.
      if(myMsg->protocol == PROTOCOL_NEIGHBOR){
         dbg(NEIGHBOR_CHANNEL, "Node %d received discovery from node %d\n", TOS_NODE_ID, myMsg->src);
         call NDiscovery.receive(*myMsg, myMsg->src);

            return msg;
        }
      if(myMsg->protocol == PROTOCOL_FLOODING){
         call Flooding.receive(*myMsg, call AMPacket.source(msg));
         return msg;
      }

      dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload);
      return msg;
   }

   dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n",len);

   return msg;
}


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      uint8_t pingPayload[FLOODING_MAX_PAYLOAD_SIZE];

      dbg(GENERAL_CHANNEL, "PING EVENT \n");

      pingPayload[0] = FLOOD_PING;
      memcpy(&pingPayload[1], payload, FLOODING_MAX_PAYLOAD_SIZE - 1);

      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_FLOODING, 0, pingPayload, FLOODING_MAX_PAYLOAD_SIZE);
      call Flooding.flood(sendPackage);
   }

   event void CommandHandler.printNeighbors(){
      call NDiscovery.printNeighbors();
   }

   event void CommandHandler.printRouteTable(){}

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
