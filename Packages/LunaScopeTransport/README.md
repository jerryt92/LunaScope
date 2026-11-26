# LunaScopeTransport

This package includes the Apple Luna adapter, wire protocol and KCP sources from OpenCine revision `80247e711f82520f64fb2d35420eba78ca353268`. It links the shared OpenCine libraries from that revision. The app uses this local copy because the pinned OpenCine Luna adapter restricts Bluetooth authorization and Wi-Fi negotiation to Luna Ultra.

LunaScope supplies supported model identifiers and Bluetooth name prefixes. The adapter checks the device-reported model during authorization and Wi-Fi negotiation. The app configures the lens and white-balance domains from the identified camera's profile. Model data lives with the app resources.

See LICENSE, NOTICE, THIRD-PARTY-NOTICES.md and Sources/LunaTransportKCP/LICENSE for upstream licensing and attribution.
