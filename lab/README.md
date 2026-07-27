# Integrated lab

This directory owns cross-component behavior:

- `topologies/` - declarative component/link layouts;
- `scenarios/` - end-to-end procedures and assertions;
- `fixtures/` - deterministic subscribers, numbers, point codes, and traffic;
- `artifacts/` - generated run reports, traces, and captures.

Individual component unit tests do not belong here. A scenario moves here when
it spans two or more network elements or swaps a simulator for a production
peer.

