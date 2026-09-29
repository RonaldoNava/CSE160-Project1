configuration FloodingC {
    provides interface Flooding;
}

implementation {
    components FloodingP;
    Flooding = FloodingP;
}