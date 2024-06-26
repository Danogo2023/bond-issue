use aiken/list
use aiken/transaction.{InlineDatum, Output, Transaction}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig}
use borrow_request/utils.{is_borrower_authenticated}
use common/time.{get_current_epoch_with_ttl}

pub fn spending(
  cfg: BondIssueConfig,
  tx: Transaction,
  sbond: Output,
  sbond_dt: BondDatum,
  bond_nft_pid: PolicyId,
  borrower_pid: PolicyId,
) -> Bool {
  and {
    is_borrower_authenticated(tx, borrower_pid, sbond_dt.borrower)?,
    constraint(cfg, tx, sbond, sbond_dt, bond_nft_pid),
  }
}

pub fn constraint(
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
        o.address.payment_credential == sbond.address.payment_credential && //
        value.quantity_of(o.value, bond_nft_pid, sbond_dt.token_name) == 1
      },
    )
  is {
    [obond] -> {
      expect obond_dt: BondDatum =
        when obond.datum is {
          InlineDatum(d) -> d
          _ ->
            fail @"borrow_position/change_stake_key.constraint: only supports InlineDatum for bond"
        }
      and {
        is_before_maturity_and_not_redeem_fee(cfg, tx, sbond_dt),
        (obond.address.stake_credential != None)?,
        (obond_dt.bond_symbol == sbond_dt.bond_symbol)?,
        (obond_dt.token_name == sbond_dt.token_name)?,
        (obond_dt.borrower == sbond_dt.borrower)?,
        (obond_dt.epo_rewards == sbond_dt.epo_rewards)?,
        (obond_dt.duration == sbond_dt.duration)?,
        (obond_dt.bond_amount == sbond_dt.bond_amount)?,
        (obond_dt.buffer == sbond_dt.buffer)?,
        (obond_dt.fee == sbond_dt.fee)?,
        (obond_dt.start == sbond_dt.start)?,
        (obond.value == sbond.value)?,
      }
    }
    _ ->
      fail @"borrow_position/change_stake_key.constraint: bond utxo output invalid"
  }
}

fn is_before_maturity_and_not_redeem_fee(
  cfg: BondIssueConfig,
  tx: Transaction,
  sbond_dt: BondDatum,
) {
  let epoch_curr =
    get_current_epoch_with_ttl(
      tx.validity_range,
      cfg.epoch,
      cfg.platform.tx_ttl,
      cfg.slot.slot_length,
    )
  and {
    (sbond_dt.fee > 0)?,
    (epoch_curr < sbond_dt.start + cfg.epoch.epoch_boundary_as_epoch + sbond_dt.duration)?,
  }
}
