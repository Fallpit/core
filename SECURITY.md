# Security

## Reporting a vulnerability

Email **hi@fallpit.xyz** with the details and, if you can, a proof of concept. Do not open a public issue or
pull request for a vulnerability.

## Scope

The contracts in `src/` as deployed in `deployments/<chainId>.json` (Robinhood Chain mainnet 4663). The
contracts cannot be upgraded. Owner changes that affect pricing take effect 24 hours after they are
announced on chain.

## Status

The contracts have not had a third-party audit. They have had two internal reviews and a blind review
(none critical or high). Use them at your own risk.
