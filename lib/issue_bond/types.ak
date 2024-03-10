use aiken/transaction/value.{PolicyId}

pub type BondIssueAction {
  RequestCreate { req_nft_pid: PolicyId }
  RequestUpdate
  BondCreate { req_nft_pid: PolicyId }
  BondRedeem
  BondPayInterest
  BondChangeStakeKey
  RedeemFee
}
