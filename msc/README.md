# MSC/VLR component

Status: scaffolded; this is the next planned network element.

This component will own MSC/VLR call and mobility state, including selected
BSSAP/DTAP, MAP, and ISUP procedures plus a replaceable signaling endpoint.
Mixed-generation SIP/IMS interworking will be an adapter rather than code
inside the STP.

Planned local layout:

- `src/` - OTP application and call/mobility state machines;
- `test/` - protocol vectors and end-to-end call scenarios;
- `config/` - simulated and production STP attachment profiles.

