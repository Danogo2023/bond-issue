use aiken/transaction.{Mint, ScriptContext}
use common/types.{PublicKeyHash} as common_types
use common/util.{must_be_signed_by_key}
use issue_bond/utils as issue_bond_utils
use protocol_params/types.{BurnProtocol,
  MintProtocol, ProtocolParamsAction} as protocol_params_types

// deployment order: 1
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
