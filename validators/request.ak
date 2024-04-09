use aiken/transaction.{Mint, ScriptContext, Spend}
use aiken/transaction/value.{AssetName, PolicyId}
use bond_issue/types.{BondIssueConfig, RequestDatum}
use borrow_request/bond_create
use borrow_request/request_nft
use borrow_request/request_update
use issue_bond/types.{BondCreate,
  BondIssueAction, RequestCreate, RequestUpdate} as issue_bond_types
use issue_bond/utils as issue_bond_utils
use protocol_params/types.{ProtocolParams} as protocol_params_types
use protocol_params/utils.{get_protocol_params}

// deployment order: 2
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

// deployment order: 2
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
        let ProtocolParams { borrower_pid, borrow_request_skh, .. } =
          get_protocol_params(protocol_nft_pid, protocol_nft_name, tx)
        request_nft.minting(
          cfg,
          tx,
          req_nft_pid,
          borrow_request_skh,
          borrower_pid,
        )
      }
      BondCreate -> request_nft.burning_valid(tx, req_nft_pid)
      RequestUpdate -> request_nft.burning_valid(tx, req_nft_pid)
      _ ->
        fail @"minting request nft only support RequestCreate | RequestUpdate | BondCreate action"
    }
  }
}

// deployment order: 2
validator(
  protocol_nft_pid: PolicyId,
  protocol_nft_name: AssetName,
  cfg: BondIssueConfig,
) {
  fn spend_request(
    sdt: RequestDatum,
    ac: BondIssueAction,
    ctx: ScriptContext,
  ) -> Bool {
    expect Spend(_) = ctx.purpose
    when ac is {
      BondCreate -> {
        let ProtocolParams { bond_nft_pid, bond_skh, bond_token_pid, .. } =
          get_protocol_params(
            protocol_nft_pid,
            protocol_nft_name,
            ctx.transaction,
          )
        bond_create.spending(
          cfg,
          ctx,
          sdt,
          bond_nft_pid,
          bond_skh,
          bond_token_pid,
        )
      }
      RequestUpdate -> request_update.spending(cfg, ctx, sdt)
      _ ->
        fail @"spending borrow request only support BondCreate | RequestUpdate action"
    }
  }
}
