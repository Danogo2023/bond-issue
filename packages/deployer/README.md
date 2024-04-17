# Description

Deploying Bond Issue smart contract automatically

## Prerequisites

- Requires [Bun](https://bun.sh/) as node engine
- Environment Variables
  - `SEED`: a passphrase for signing automatically
    - **Note**: Do know the risk when using this variable
  - `KOIOS_PROJECT_ID` (optional): a string of Koios's project id. Give empty if using public plan

## Usage

- Using Makefile: `make deploy-bond-issue`
- Or running directly file for debugging: `bun run deploy.ts`

## Deployment Order

```mermaid
stateDiagram
direction LR
[*] --> protocol_validator
protocol_validator --> protocol_nft
protocol_nft --> bond_nft_validator
protocol_nft --> bond_token_validator
protocol_nft --> borrower_nft_validator
protocol_nft --> borrow_request_validator

borrower_nft_validator --> protocol_params_utxo
borrow_request_validator --> protocol_params_utxo
bond_token_validator --> protocol_params_utxo
bond_nft_validator --> protocol_params_utxo
protocol_params_utxo --> [*]

```

## TODOs

- [ ] Integrate with CI/CD
- [ ] Add automation tests against deployed contracts
- [ ] Interactive mode without requiring signing key
- [ ] Deployment chaining: allowing dependent contracts can be chained to deploy in order
