use aiken/transaction/value.{PolicyId}

pub type ProtocolParams {
  // [multi-validator] policy id of bond_nft or script hash of bond utxo,
  bond_nft_skh: ByteArray,
  // policy id of bond token
  bond_token_pid: PolicyId,
  // policy id of borrower nft
  borrower_pid: PolicyId,
  // [multi-validator] policy id of borrow request nft or sciprt hash of borrow request utxo
  borrow_request_skh: ByteArray,
}

pub type ProtocolParamsAction {
  MintProtocol
  BurnProtocol
}
