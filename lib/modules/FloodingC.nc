configuration FloodingC {
    provides interface Flooding;
    uses interface SimpleSend as Sender;
    uses interface NDiscovery;
}

implementation {
    components FloodingP;

    Flooding = FloodingP;

    FloodingP.Sender = Sender;
    FloodingP.NDiscovery = NDiscovery;
}