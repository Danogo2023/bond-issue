use aiken/list
use aiken/transaction.{InlineDatum, Output, Transaction}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig} as bond_issue_types
use common/pvalue

pub fn spending_without_fee(
  cfg: BondIssueConfig,
  tx: Transaction,
  sbond: Output,
  sbond_dt: BondDatum,
  bond_nft_pid: PolicyId,
) -> Bool {
  when
    list.filter(
      tx.outputs,
      fn(o) {
        o.address == sbond.address && //
        value.quantity_of(o.value, bond_nft_pid, sbond_dt.token_name) == 1
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
      let (sbond_balance, obond_balance) =
        (value.lovelace_of(sbond.value), value.lovelace_of(obond.value))

      let interest = obond_balance - sbond_balance
      let interest_min =
        value.lovelace_of(pvalue.to_value(sbond_dt.epo_rewards))

      let sbond_principal = sbond_dt.bond_amount * cfg.platform.bond_face_value
      let sbond_interest_paid = sbond_balance - sbond_principal
      let sbond_paid_epoch = sbond_interest_paid / interest_min
      let interest_max = interest_min * ( sbond_dt.duration - sbond_paid_epoch )
      and {
        (sbond_dt.fee > 0)?,
        (interest > 0)?,
        (interest_max > 0)?,
        (interest >= interest_min)?,
        (interest <= interest_max)?,
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
      }
    }
    _ -> fail @"bond output invalid"
  }
}
