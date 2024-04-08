use aiken/builtin
use aiken/cbor

pub type BondIssueAction {
  RequestCreate
  RequestUpdate
  BondCreate
  BondRedeem
  BondPayInterest
  BondChangeStakeKey
  RedeemFee
}

pub fn to_multi_validator_redeemer(rdr: BondIssueAction) {
  // convert rdr to Data
  let (tag, dataList) = builtin.un_constr_data(rdr)
  let rdr_data = builtin.constr_data(tag, dataList)
  // wrap the data to a constructor with tag 122
  builtin.constr_data(1, [rdr_data])
}

pub fn unpack_multi_validator_redeemer(rdr: Data) {
  let (tag, dataList) = builtin.un_constr_data(rdr)
  expect tag == 1
  expect [rdr] = dataList
  rdr
}

test multi_validator_redeemer() {
  let rdr = to_multi_validator_redeemer(BondRedeem)
  trace cbor.diagnostic(rdr)
  expect action: BondIssueAction = unpack_multi_validator_redeemer(rdr)
  action == BondRedeem
}
