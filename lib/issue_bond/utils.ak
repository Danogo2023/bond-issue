use aiken/dict
use aiken/list
use aiken/math
use aiken/transaction.{Input, Output, Transaction}
use aiken/transaction/credential.{ScriptCredential, VerificationKeyCredential}
use aiken/transaction/value.{AssetName, PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig, RequestDatum}
use common/hash_out_refs.{hash_out_ref}
use common/pvalue
use common/time.{get_current_epoch_with_ttl}
use common/types.{Lovelace} as common_types

pub fn burn_nft(tx: Transaction, pid: PolicyId) -> Bool {
  let burn_names = get_burn_nft_names(tx, pid)
  (list.length(burn_names) > 0)?
}

pub fn mint_nft(tx: Transaction, pid: PolicyId) -> Bool {
  let nft_name_avaiable =
    list.map(tx.inputs, fn(i) { hash_out_ref(i.output_reference) })

  let nft_mint = value.tokens(value.from_minted_value(tx.mint), pid)
  let nft_mint_valid =
    dict.foldr(
      nft_mint,
      0,
      fn(n, q, z) {
        if list.has(nft_name_avaiable, n)? && (q == 1)? {
          z + 1
        } else {
          fail @"must mint only one"
        }
      },
    )
  (dict.size(nft_mint) == nft_mint_valid)?
}

pub fn get_burn_token_names(tx: Transaction, pid: PolicyId) -> List<AssetName> {
  dict.foldr(
    value.from_minted_value(tx.mint) |> value.tokens(pid),
    [],
    fn(n, q, z) {
      if (q < 0)? {
        [n, ..z]
      } else {
        fail
      }
    },
  )
}

pub fn get_burn_nft_names(tx: Transaction, pid: PolicyId) -> List<AssetName> {
  dict.foldr(
    value.from_minted_value(tx.mint) |> value.tokens(pid),
    [],
    fn(n, q, z) {
      if (q == -1)? {
        [n, ..z]
      } else {
        fail
      }
    },
  )
}

pub fn get_input_by_nft_names(
  tx: Transaction,
  nft_names: List<AssetName>,
  nft_pid: PolicyId,
) -> List<Input> {
  list.filter(
    tx.inputs,
    fn(i) {
      when i.output.address.payment_credential is {
        VerificationKeyCredential(_) -> False
        ScriptCredential(_) -> True
      } && //
      when
        list.find(
          nft_names,
          fn(n) { value.quantity_of(i.output.value, nft_pid, n) == 1 },
        )
      is {
        Some(_) -> True
        _ -> False
      }
    },
  )
}

pub fn get_output_by_nft_names(
  tx: Transaction,
  nft_names: List<AssetName>,
  nft_pid: PolicyId,
) -> List<Output> {
  list.filter(
    tx.outputs,
    fn(o) {
      when
        list.find(
          nft_names,
          fn(n) { value.quantity_of(o.value, nft_pid, n) > 0 },
        )
      is {
        Some(_) -> True
        _ -> False
      }
    },
  )
}

pub fn check_output_request_base(
  cfg: BondIssueConfig,
  o: Output,
  oreq_dt: RequestDatum,
) -> Bool {
  and {
    (oreq_dt.apr >= cfg.platform.min_apr)?,
    (oreq_dt.duration >= cfg.platform.min_duration)?,
    (oreq_dt.requested >= cfg.platform.min_requested)?,
    (oreq_dt.buffer >= cfg.platform.min_buffer)?,
    (oreq_dt.prepaid >= math.min(
      oreq_dt.buffer + cfg.platform.prepaid_plus,
      oreq_dt.duration,
    ))?,
    (oreq_dt.prepaid <= oreq_dt.duration)?,
    (oreq_dt.fee >= cfg.platform.fee)?,
    (oreq_dt.epo_rewards >= ( oreq_dt.requested - oreq_dt.issued ) * cfg.platform.bond_face_value * oreq_dt.apr / cfg.basis.base / cfg.epoch.year_to_epoch)?,
    (value.lovelace_of(o.value) >= cfg.platform.min_ada + oreq_dt.epo_rewards * oreq_dt.prepaid)?,
  }
}

pub fn bond_closable(
  cfg: BondIssueConfig,
  tx: Transaction,
  sbond_dt: BondDatum,
  sbond_interest_paid: Lovelace,
) -> Bool {
  let epoch_curr =
    get_current_epoch_with_ttl(
      tx.validity_range,
      cfg.epoch,
      cfg.platform.tx_ttl,
      cfg.slot.slot_length,
    )
  let epoch_start = sbond_dt.start + cfg.epoch.epoch_boundary_as_epoch
  let epoch_end = epoch_start + sbond_dt.duration
  let epoch_passed =
    if epoch_curr >= epoch_end {
      sbond_dt.duration
    } else {
      epoch_curr - epoch_start + 1
    }
  let epoch_required_premium =
    epoch_passed + if epoch_curr >= epoch_end {
      0
    } else {
      sbond_dt.buffer
    }
  let sbond_paid_epoch =
    sbond_interest_paid / value.lovelace_of(
      pvalue.to_value(sbond_dt.epo_rewards),
    )
  or {
    (epoch_curr >= epoch_end)?,
    (sbond_paid_epoch < epoch_required_premium)?,
  }
}

fn fail_if_false(predicate: Bool, msg: String) {
  if !predicate {
    fail msg
  } else {
    True
  }
}

pub fn bond_asset_valid(
  bond_nft_pid: PolicyId,
  obond_dt: BondDatum,
  obond: Output,
  obond_paid: Int,
) -> Bool {
  let ada_qty = value.lovelace_of(obond.value)
  let bond_nft_qty =
    value.quantity_of(obond.value, bond_nft_pid, obond_dt.token_name)
  and {
    fail_if_false(ada_qty >= obond_paid, @"lovelace qty of bond ouput invalid"),
    fail_if_false(bond_nft_qty == 1, @"bond nft qty of bond ouput invalid"),
  }
}

pub fn log(self: a, serializer: fn(a) -> String) -> a {
  trace serializer(self)
  self
}
