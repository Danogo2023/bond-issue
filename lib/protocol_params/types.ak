use aiken/transaction/value.{PolicyId}
use common/types.{ScriptKeyHash}

pub type ProtocolParams {
  // policy id of bond_nft
  bond_nft_pid: PolicyId,
  // script hash of bond utxo,
  bond_skh: ScriptKeyHash,
  // policy id of bond token
  bond_token_pid: PolicyId,
  // policy id of borrower nft
  borrower_pid: PolicyId,
  // policy id of borrow request nft
  borrow_request_pid: PolicyId,
  // sciprt hash of borrow request utxo
  borrow_request_skh: ScriptKeyHash,
}

pub type ProtocolParamsAction {
  MintProtocol
  BurnProtocol
}
