pub type BondIssueAction {
  RequestCreate
  RequestUpdate
  BondCreate
  BondRedeem
  BondPayInterest
  BondChangeStakeKey
  RedeemFee
}

pub type BondIssueActionWrapper {
  wrapper: BondIssueAction,
}
