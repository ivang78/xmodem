## XModem / YModem

Implementation of XModem (Send/Receive) and YModem (Send only) used to connect from modern PC to CP/M computer with fast UART port like [ZX2022 computer](https://github.com/michalin/ZX2022). 
Common difference to other implementations is a adjustable send UART delay in milliseconds. This delay let slow Z80 CPU receive all bytes from UART without interrupts cause old CP/M terminal software, like XTerm/XModem and QTerm do not use interrupts. 

## Compiling

Use Lazarus 3 and [Lazserial](https://github.com/JurassicPork/TLazSerial/) component to compile project. 
