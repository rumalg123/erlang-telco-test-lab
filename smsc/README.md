# SMSC component

Status: scaffolded.

This component will own MAP MO/MT SMS behavior, store-and-forward queues,
delivery reports, retry policy, and SMPP-facing adapters. It will attach to
the STP through a signaling endpoint that can instead target a production STP.

