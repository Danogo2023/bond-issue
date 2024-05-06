use aiken/dict
use aiken/list
use aiken/transaction.{Input, Mint, Output, Transaction}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig} as bond_issue_types
use common/data
use common/time.{get_current_epoch_with_ttl}
use common/types.{ScriptKeyHash}
use issue_bond/types.{BondIssueAction, RedeemForce} as issue_bond_types

/// There might exist lenders who cannot redeem their bond tokens due to
/// cetain reasons (e.g: lost their signing keys). Meaning that the funds
/// will be locked forever at the bond utxo and the bond utxo will 
/// never be burned. So we deal with this case by allowing protocol to
/// redeem uncontrolled bonds after a dealine since bond maturity epoch.
pub fn burn_bond_nft(
  cfg: BondIssueConfig,
  tx: Transaction,
  nft_pid: PolicyId,
  bond_nft_skh: ScriptKeyHash,
  redeem_over_epochs: Int,
) -> Bool {
  // Allow only single redemption in a transaction
  expect [Input { output: sbond, .. }] =
    list.filter(
      tx.inputs,
      fn(i) {
        i.output.address.payment_credential == ScriptCredential(bond_nft_skh)
      },
    )
  expect sbond_dt: BondDatum = data.output_datum(sbond)

  and {
    // Must be triggered after the deadline
    {
      let epoch_curr =
        get_current_epoch_with_ttl(
          tx.validity_range,
          cfg.epoch,
          cfg.platform.tx_ttl,
          cfg.slot.slot_length,
        )
      let epoch_end =
        sbond_dt.start + cfg.epoch.epoch_boundary_as_epoch + sbond_dt.duration
      let epoch_deadline = epoch_end + redeem_over_epochs
      (epoch_curr >= epoch_deadline)?
    },
    // Funds must be sent to the fee address
    {
      expect [ofee] =
        list.filter(tx.outputs, fn(o) { o.address == cfg.platform.fee_addr })
      let sbond_balance = value.lovelace_of(sbond.value)
      let ofee_balance = value.lovelace_of(ofee.value)
      (ofee_balance >= sbond_balance)?
    },
    // Must burn nft and doesn't mint/burn others
    {
      expect [(pid, name, qty)] =
        tx.mint |> value.from_minted_value |> value.flatten
      and {
        pid == nft_pid,
        (name == sbond_dt.token_name)?,
        (qty == -1)?,
      }
    },
  }
}

pub fn spend_bond(tx: Transaction, bond_nft_pid: PolicyId) {
  expect Some(rdr_data) = dict.get(tx.redeemers, Mint(bond_nft_pid))
  expect action: BondIssueAction = rdr_data
  (action == RedeemForce)?
}
