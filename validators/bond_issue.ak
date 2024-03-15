use aiken/list
use aiken/transaction.{Mint, ScriptContext, Spend}
use aiken/transaction/credential.{ScriptCredential, StakeCredential}
use aiken/transaction/value.{AssetName, PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig, RequestDatum}
use borrow_position/change_stake_key
use borrow_position/mint_bond
use borrow_position/pay_interest
use borrow_position/redeem_bond
use borrow_position/redeem_fee
use borrow_request/bond_create
use borrow_request/request_nft
use borrow_request/request_update
use common/types.{PublicKeyHash} as common_types
use common/util.{must_be_signed_by_key}
use issue_bond/types.{
  BondChangeStakeKey, BondCreate, BondIssueAction, BondPayInterest, BondRedeem,
  RedeemFee, RequestCreate, RequestUpdate,
} as issue_bond_types
use issue_bond/utils as issue_bond_utils
use protocol_params/types.{
  BurnProtocol, MintProtocol, ProtocolParams, ProtocolParamsAction,
} as protocol_params_types
use protocol_params/utils.{get_protocol_params}

// num deploy 1
validator(owner: PublicKeyHash) {
  fn mint_protocol(ac: ProtocolParamsAction, ctx: ScriptContext) -> Bool {
    expect Mint(protocol_pid) = ctx.purpose
    let tx = ctx.transaction
    and {
      must_be_signed_by_key(tx.extra_signatories, owner)?,
      when ac is {
        MintProtocol -> issue_bond_utils.mint_nft(tx, protocol_pid)
        BurnProtocol -> issue_bond_utils.burn_nft(tx, protocol_pid)
      },
    }
  }

  fn spend_protocol(_sdt: Data, _ac: Data, _ctx: Data) -> Bool {
    False
  }
}

// num deploy 2
validator {
  fn mint_borrower_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(borrower_pid) = ctx.purpose
    let tx = ctx.transaction
    when ac is {
      RequestCreate -> issue_bond_utils.mint_nft(tx, borrower_pid)
      RequestUpdate -> issue_bond_utils.burn_nft(tx, borrower_pid)
      _ ->
        fail @"minting borrower nft only support RequestCreate | RequestUpdate action"
    }
  }
}

// num deploy 3
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
) {
  fn mint_request_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(req_nft_pid) = ctx.purpose
    let tx = ctx.transaction
    when ac is {
      RequestCreate -> {
        let ProtocolParams { borrower_pid, .. } =
          get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
        request_nft.minting(cfg, tx, req_nft_pid, borrower_pid)
      }
      BondCreate -> request_nft.burning_valid(tx, req_nft_pid)
      RequestUpdate -> request_nft.burning_valid(tx, req_nft_pid)
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
      BondCreate -> {
        let ProtocolParams { bond_nft_skh: bond_nft_pid, bond_token_pid, .. } =
          get_protocol_params(
            protocol_nft_pid,
            protocol_nft_name,
            ctx.transaction,
          )
        bond_create.spending(cfg, ctx, sdt, bond_nft_pid, bond_token_pid)
      }
      RequestUpdate -> request_update.spending(cfg, ctx, sdt)
      _ ->
        fail @"spending borrow request only support BondCreate | RequestUpdate action"
    }
  }
}

// num deploy 4
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
) {
  fn mint_bond_token(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(bond_token_pid) = ctx.purpose
    let tx = ctx.transaction
    let ProtocolParams { bond_nft_skh: bond_nft_pid, .. } =
      get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
    when ac is {
      BondCreate -> mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid)
      BondRedeem -> mint_bond.burn_bond_token(tx, bond_nft_pid, bond_token_pid)
      _ ->
        fail @"minting bond token only support BondCreate | BondRedeem action"
    }
  }
}

// num deploy 5
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
  default_stake_cred: StakeCredential,
) {
  fn mint_bond_nft(ac: BondIssueAction, ctx: ScriptContext) -> Bool {
    expect Mint(_bond_nft_pid) = ctx.purpose
    let tx = ctx.transaction
    let ProtocolParams { bond_token_pid, .. } =
      get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
    when ac is {
      BondCreate ->
        mint_bond.create_bond_nft_with_bond_token_redeemer(tx, bond_token_pid)
      BondRedeem ->
        mint_bond.burn_bond_nft_with_bond_token_redeemer(tx, bond_token_pid)
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
      BondChangeStakeKey -> {
        let ProtocolParams { borrower_pid, .. } =
          get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
        change_stake_key.spending(
          cfg,
          tx,
          sbond,
          sdt,
          bond_nft_pid,
          borrower_pid,
        )
      }
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
