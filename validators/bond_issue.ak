use aiken/list
use aiken/transaction.{Mint, ScriptContext, Spend}
use aiken/transaction/credential.{ScriptCredential, StakeCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig, RequestDatum}
use borrow_position/bond_nft
use borrow_position/bond_token
use borrow_position/change_stake_key
use borrow_position/pay_interest
use borrow_position/redeem_bond
use borrow_position/redeem_fee
use borrow_request/bond_create
use borrow_request/borrower_nft
use borrow_request/request_nft
use borrow_request/request_update
use issue_bond/types.{
  BondChangeStakeKey, BondCreate, BondIssueAction, BondPayInterest, BondRedeem,
  RedeemFee, RequestCreate, RequestUpdate,
} as issue_bond_types

// num deploy 1
validator(cfg: BondIssueConfig) {
  fn mint_borrower_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(borrower_pid) = ctx.purpose
    let tx = ctx.transaction
    when ac is {
      RequestCreate { req_nft_pid } ->
        borrower_nft.minting(cfg, tx, req_nft_pid, borrower_pid)
      RequestUpdate -> borrower_nft.burning_force_redeem(tx, borrower_pid)
      _ ->
        fail @"minting borrower nft only support RequestCreate | RequestUpdate action"
    }
  }
}

// num deploy 2
validator(
  cfg: BondIssueConfig,
  borrower_pid: PolicyId,
  default_stake_cred: StakeCredential,
) {
  fn mint_bond_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(bond_nft_pid) = ctx.purpose
    let tx = ctx.transaction
    when ac is {
      BondCreate { req_nft_pid } ->
        bond_nft.minting(cfg, tx, bond_nft_pid, req_nft_pid)
      BondRedeem -> bond_nft.burning_bond_redeem(tx, bond_nft_pid)
      _ -> fail @"minting bond nft only support BondCreate | BondRedeem action"
    }
  }

  fn spend_position(
    sdt: BondDatum,
    ac: BondIssueAction,
    ctx: ScriptContext,
  ) -> Bool {
    expect Spend(out_ref) = ctx.purpose
    let tx = ctx.transaction
    expect Some(ibond) =
      list.find(tx.inputs, fn(i) { i.output_reference == out_ref })
    let sbond = ibond.output
    expect ScriptCredential(bond_nft_pid) = sbond.address.payment_credential

    when ac is {
      BondRedeem ->
        redeem_bond.spending_with_fee(cfg, tx, sbond, sdt, bond_nft_pid)
      BondPayInterest ->
        pay_interest.spending_without_fee(cfg, tx, sbond, sdt, bond_nft_pid)
      BondChangeStakeKey ->
        change_stake_key.spending(
          cfg,
          tx,
          sbond,
          sdt,
          bond_nft_pid,
          borrower_pid,
        )
      RedeemFee ->
        redeem_fee.spending(
          cfg,
          tx,
          sbond,
          sdt,
          bond_nft_pid,
          default_stake_cred,
        )
      _ ->
        fail @"spending bond position only support BondRedeem | BondPayInterest | BondChangeStakeKey | RedeemFee action"
    }
  }
}

// num deploy 4
validator(cfg: BondIssueConfig, bond_nft_pid: PolicyId) {
  fn mint_bond_token(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(bond_token_pid) = ctx.purpose
    let tx = ctx.transaction
    when ac is {
      BondCreate { req_nft_pid } ->
        bond_token.minting_without_fee(
          cfg,
          tx,
          req_nft_pid,
          bond_nft_pid,
          bond_token_pid,
        )
      BondRedeem ->
        bond_token.burning_bond_redeem(tx, bond_token_pid, bond_nft_pid)
      _ ->
        fail @"minting bond token only support BondCreate | BondRedeem action"
    }
  }
}

// num deploy 5
validator(
  cfg: BondIssueConfig,
  borrower_pid: PolicyId,
  bond_nft_pid: PolicyId,
  bond_token_pid: PolicyId,
) {
  fn mint_request_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(req_nft_pid) = ctx.purpose
    let tx = ctx.transaction
    when ac is {
      RequestCreate { .. } ->
        request_nft.minting(cfg, tx, req_nft_pid, borrower_pid)
      BondCreate { .. } ->
        request_nft.burning_bond_create(
          tx,
          bond_nft_pid,
          req_nft_pid,
          borrower_pid,
        )
      RequestUpdate -> request_nft.burning_request_update(tx, req_nft_pid)
      _ ->
        fail @"minting request nft only support RequestCreate | RequestUpdate | BondCreate action"
    }
  }

  fn spend_request(
    sdt: RequestDatum,
    ac: BondIssueAction,
    ctx: ScriptContext,
  ) -> Bool {
    when ac is {
      BondCreate { .. } ->
        bond_create.spending(cfg, ctx, sdt, bond_nft_pid, bond_token_pid)
      RequestUpdate -> request_update.spending(cfg, ctx, sdt)
      _ ->
        fail @"spending borrow request only support BondCreate | RequestUpdate action"
    }
  }
}
