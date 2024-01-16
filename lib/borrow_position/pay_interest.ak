use aiken/list
use aiken/transaction.{InlineDatum, Output, Transaction}
use aiken/transaction/credential.{Address}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum} as bond_issue_types

pub fn spending_without_fee(
  tx: Transaction,
  sbond: Output,
  sbond_addr: Address,
  sbond_dt: BondDatum,
  nft_pid: PolicyId,
) -> Bool {
  when
    list.filter(
      tx.outputs,
      fn(o) {
        o.address == sbond_addr && //
        value.quantity_of(o.value, nft_pid, sbond_dt.token_name) == 1
      },
    )
  is {
    [obond] -> {
      expect obond_dt: BondDatum =
        when obond.datum is {
          InlineDatum(d) -> d
          _ ->
            fail @"borrow_position/pay_interest.spending_without_fee: only supports InlineDatum for bond"
        }
      let (sbond_assets, obond_assets) =
        (
          value.without_lovelace(sbond.value),
          value.without_lovelace(obond.value),
        )
      let (sbond_lovelace, obond_lovelace) =
        (value.lovelace_of(sbond.value), value.lovelace_of(obond.value))

      let interest = obond_lovelace - sbond_lovelace
      let interest_min = value.lovelace_of(sbond_dt.epo_rewards)
      let interest_max = interest_min * sbond_dt.duration
      and {
        (sbond_dt.fee > 0)?,
        (obond_assets == sbond_assets)?,
        (obond_dt.epo_rewards == sbond_dt.epo_rewards)?,
        (obond_dt.duration == sbond_dt.duration)?,
        (obond_dt.bond_symbol == sbond_dt.bond_symbol)?,
        (obond_dt.token_name == sbond_dt.token_name)?,
        (obond_dt.bond_amount == sbond_dt.bond_amount)?,
        (obond_dt.buffer == sbond_dt.buffer)?,
        (obond_dt.fee == sbond_dt.fee)?,
        (obond_dt.borrower == sbond_dt.borrower)?,
        (obond_dt.start == sbond_dt.start)?,
        (interest > 0)?,
        (interest >= interest_min)?,
        (interest <= interest_max)?,
      }
    }
    _ -> fail @"bond output invalid"
  }
}
