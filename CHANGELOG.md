# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.4] - 2024-03-07

### Added

- Restrict that all tokens names under the borrower_nft or borrow_request_nft policy must be hashed by a spending out ref
- Implement new redeemer borrower_nft::RequestUpdate to allow burning borrower nft

## [1.0.3] - 2024-01-30

This is the first documented and supported implementation. It contains some main points:

### Added

- borrow_request: Add `request_nft` 
- borrow_request: Add `borrower_nft` 
- borrow_request: Add `bond_create` 
- borrow_position: Add `bond_nft` 
- borrow_position: Add `bond_token` 
- borrow_position: Add `change_stake_key` 
- borrow_position: Add `pay_interest` 
- borrow_position: Add `redeem_bond` 
- borrow_position: Add `redeem_fee` 
- borrow_position: Add `redeem_force` 
- issue_bond: Add `utils` with `garbage_collector_request` 
  and `garbage_collector_position`
- validators: 
  Add `bond_issue` with `mint_borrower`, `spend_position`, 
  `mint_nft`, `mint_token`, `spend_request`, `mint_request`

All future Changelog entries will reference this base

[unreleased]: https://github.com/danogo2023/bond-issue/compare/v1.0.3...HEAD
[1.0.4]: https://github.com/danogo2023/bond-issue/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/danogo2023/bond-issue/compare/v0.0.1...v1.0.3
