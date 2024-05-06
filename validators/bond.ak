use aiken/list
use aiken/transaction.{Mint, ScriptContext, Spend}
use aiken/transaction/credential.{StakeCredential}
use aiken/transaction/value.{AssetName, PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig}
use borrow_position/change_stake_key
use borrow_position/mint_bond
use borrow_position/pay_interest
use borrow_position/redeem_bond
use borrow_position/redeem_fee
use borrow_position/redeem_force
use issue_bond/types.{
  BondChangeStakeKey, BondCreate, BondIssueAction, BondPayInterest, BondRedeem,
  RedeemFee, RedeemForce,
} as issue_bond_types
use protocol_params/types.{ProtocolParams} as protocol_params_types
use protocol_params/utils.{get_protocol_params}

// deployment order: 2
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
) {
  fn mint_bond_token(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(bond_token_pid) = ctx.purpose
    let tx = ctx.transaction
    let ProtocolParams { bond_nft_pid, bond_skh, .. } =
      get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
    when ac is {
      BondCreate ->
        mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid, bond_skh)
      BondRedeem ->
        mint_bond.burn_bond_token(tx, bond_nft_pid, bond_token_pid, bond_skh)
      _ ->
        fail @"minting bond token only support BondCreate | BondRedeem action"
    }
  }
}

// deployment order: 2
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
  redeem_over_epochs: Int,
) {
  fn mint_bond_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(_) = ctx.purpose
    let tx = ctx.transaction
    let ProtocolParams { bond_token_pid, bond_nft_pid, bond_skh, .. } =
      get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
    when ac is {
      BondCreate ->
        mint_bond.create_bond_nft_with_bond_token_redeemer(tx, bond_token_pid)
      BondRedeem ->
        mint_bond.burn_bond_nft_with_bond_token_redeemer(tx, bond_token_pid)
      RedeemForce ->
        redeem_force.burn_bond_nft(
          cfg,
          tx,
          bond_nft_pid,
          bond_skh,
          redeem_over_epochs,
        )
      _ -> fail @"Invalid redeemer"
    }
  }
}

// deployment order: 2
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
  default_stake_cred: StakeCredential,
) {
  fn spend_bond(sdt: BondDatum, ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Spend(out_ref) = ctx.purpose
    let tx = ctx.transaction
    expect Some(ibond) =
      list.find(tx.inputs, fn(i) { i.output_reference == out_ref })
    let sbond = ibond.output
    let ProtocolParams { borrower_pid, bond_nft_pid, .. } =
      get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)

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
      RedeemForce -> redeem_force.spend_bond(tx, bond_nft_pid)
      _ ->
        fail @"spending bond position only support BondRedeem | BondPayInterest | BondChangeStakeKey | RedeemFee action"
    }
  }
}
