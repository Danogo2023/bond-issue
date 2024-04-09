use aiken/transaction/value.{PolicyId}

pub type ProtocolParams {
  // policy id of bond_nft
  bond_nft_pid: ByteArray,
  // script hash of bond utxo,
  bond_skh: ByteArray,
  // policy id of bond token
  bond_token_pid: PolicyId,
  // policy id of borrower nft
  borrower_pid: PolicyId,
  // policy id of borrow request nft
  borrow_request_pid: ByteArray,
  // sciprt hash of borrow request utxo
  borrow_request_skh: ByteArray,
}

pub type ProtocolParamsAction {
  MintProtocol
  BurnProtocol
}
