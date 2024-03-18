use aiken/bytearray
use aiken/cbor
use aiken/dict
use aiken/interval
use aiken/list
use aiken/string
use aiken/transaction.{
  InlineDatum, Input, Output, OutputReference, ScriptPurpose, Spend, Transaction,
  TransactionId,
}
use aiken/transaction/credential.{Address, Inline, VerificationKeyCredential}
use aiken/transaction/value.{PolicyId, ada_asset_name, ada_policy_id}
use bond_issue/types.{BondDatum,
  BondIssueConfig, PlatformConfig} as bond_issue_types
use borrow_position/change_stake_key
use common/pvalue
use common/time.{
  BasisPoints, get_epoch_config_mainnet, get_slot_config_network_mainnet,
  relative_epoch_to_posix_time_start,
}
use issue_bond/types.{BondChangeStakeKey}

const bond_nft_pid = "bond_nft_pid"

const bond_skh = "bond_nft_pid"

const ada = 1_000_000

// =================Builders===================

fn build_platform_cfg() {
  PlatformConfig {
    bond_face_value: 100_000_000,
    fee: 500,
    fee_addr: credential.from_verification_key("fee_addr"),
    tx_ttl: 3 * 60,
    min_buffer: 6,
    prepaid_plus: 3,
    min_requested: 100,
    min_apr: 200,
    min_duration: 6,
  }
}

fn get_datum(self: Output) -> Data {
  expect InlineDatum(datum) = self.datum
  datum
}

fn get_bond_datum(self: Output) {
  expect request_datum: BondDatum = get_datum(self)
  request_datum
}

fn build_bond_output(datum: BondDatum, stake: ByteArray) {
  let cfg = build_platform_cfg()
  let locked_value =
    ( datum.bond_amount + datum.buffer ) * cfg.bond_face_value + 2 * ada
  Output {
    address: credential.from_script(bond_skh)
      |> credential.with_delegation_key(stake),
    value: value.from_lovelace(locked_value)
      |> value.add(bond_nft_pid, datum.token_name, 1),
    datum: InlineDatum(datum),
    reference_script: None,
  }
}

fn build_bond_issue_cfg() {
  BondIssueConfig {
    slot: get_slot_config_network_mainnet(),
    epoch: get_epoch_config_mainnet(),
    basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
    platform: build_platform_cfg(),
  }
}

fn set_stake_credential(self: Output, cred: Option<ByteArray>) {
  Output {
    ..self,
    address: Address {
      ..self.address,
      stake_credential: when cred is {
        None -> None
        Some(c) -> Some(Inline(VerificationKeyCredential(c)))
      },
    },
  }
}

fn set_payment_skh(self: Output, cred: ByteArray) {
  Output {
    ..self,
    address: Address {
      ..self.address,
      payment_credential: credential.from_script(cred).payment_credential,
    },
  }
}

fn script_purpose_compare(a: ScriptPurpose, b: ScriptPurpose) {
  bytearray.compare(
    cbor.diagnostic(a) |> string.to_bytearray,
    cbor.diagnostic(b) |> string.to_bytearray,
  )
}

fn get_tx_validity_range() {
  let cfg = build_bond_issue_cfg()
  let tx_at = relative_epoch_to_posix_time_start(780, cfg.epoch)
  interval.between(tx_at, tx_at + 30_000)
}

fn build_tx(bonds: List<(Input, List<Output>)>) {
  let t = transaction.placeholder()
  let (inputs, outputs, redeemers) =
    bonds
      |> list.reduce(
          ([], [], t.redeemers),
          fn(results, descriptor) {
            let (inputs, outputs, redeemers) = results
            let (sbond, obonds) = descriptor
            (
              [sbond, ..inputs],
              outputs |> list.concat(obonds),
              redeemers
                |> dict.insert(
                    Spend(sbond.output_reference),
                    BondChangeStakeKey,
                    script_purpose_compare,
                  ),
            )
          },
        )
  (
    Transaction {
      ..transaction.placeholder(),
      validity_range: get_tx_validity_range(),
      redeemers: redeemers,
      inputs: inputs,
      outputs: outputs,
    },
    bonds |> list.map(fn(descriptor) { descriptor.1st.output }),
  )
}

fn add_asset(self: Output, pid: PolicyId, name: ByteArray, amt: Int) {
  Output { ..self, value: self.value |> value.add(pid, name, amt) }
}

fn set_bond_datum(self: Output, updater: fn(BondDatum) -> BondDatum) {
  Output { ..self, datum: InlineDatum(updater(get_bond_datum(self))) }
}

// =================Implementation===================

fn validate(output_desriptor: fn(Output) -> Output) {
  let platform_cfg = build_platform_cfg()
  let bond_issue_cfg =
    BondIssueConfig {
      slot: get_slot_config_network_mainnet(),
      epoch: get_epoch_config_mainnet(),
      basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
      platform: platform_cfg,
    }

  let bond_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada) |> pvalue.from_value,
      bond_symbol: "bond_symbol_1",
      token_name: "bond_name_1",
      bond_amount: 100,
      fee: 500,
      borrower: "borrower_1",
      start: 450,
      buffer: platform_cfg.min_buffer,
      duration: platform_cfg.min_duration,
    }
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_sbond_1"), 0),
      output: build_bond_output(bond_datum, "owner"),
    }
  expect (tx, [bond]) = build_tx([(sbond, [sbond.output |> output_desriptor])])
  change_stake_key.constraint(
    cfg: bond_issue_cfg,
    tx: tx,
    sbond: bond,
    sbond_dt: get_bond_datum(bond),
    bond_nft_pid: bond_nft_pid,
  )
}

test succ_when_all_rules_are_satisfied() {
  validate(fn(obond) { obond |> set_stake_credential(Some("new_owner")) })
}

// Address
test fail_when_setting_incorrect_payment_credential() fail {
  validate(
    fn(obond) {
      obond
        |> set_stake_credential(Some("new_owner"))
        |> set_payment_skh("other_skh")
    },
  )
}

test fail_when_setting_stake_credential_to_none() {
  !validate(
    fn(obond) {
      obond
        |> set_stake_credential(None)
    },
  )
}

// Datum
test fail_when_setting_incorrect_epo_rewards_ada() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) {
              BondDatum {
                ..datum,
                epo_rewards: datum.epo_rewards
                  |> pvalue.to_value
                  |> value.add(value.ada_policy_id, value.ada_asset_name, -1)
                  |> pvalue.from_value,
              }
            },
          )
    },
  )
}

test fail_when_setting_lower_duration() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, duration: datum.duration - 1 } },
          )
    },
  )
}

test fail_when_setting_higher_duration() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, duration: datum.duration + 1 } },
          )
    },
  )
}

test fail_when_setting_incorrect_bond_symbol() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, bond_symbol: "other_symbol" } },
          )
    },
  )
}

test fail_when_setting_incorrect_token_name() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, token_name: "other_name" } },
          )
    },
  )
}

test fail_when_setting_lower_bond_amount() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) {
              BondDatum { ..datum, bond_amount: datum.bond_amount - 1 }
            },
          )
    },
  )
}

test fail_when_setting_higher_bond_amount() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) {
              BondDatum { ..datum, bond_amount: datum.bond_amount + 1 }
            },
          )
    },
  )
}

test fail_when_setting_lower_buffer() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, buffer: datum.buffer - 1 } },
          )
    },
  )
}

test fail_when_setting_higher_buffer() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, buffer: datum.buffer + 1 } },
          )
    },
  )
}

test fail_when_setting_lower_fee() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(fn(datum) { BondDatum { ..datum, fee: datum.fee - 1 } })
    },
  )
}

test fail_when_setting_higher_fee() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(fn(datum) { BondDatum { ..datum, fee: datum.fee + 1 } })
    },
  )
}

test fail_when_setting_incorrect_borrower() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(fn(datum) { BondDatum { ..datum, borrower: "other" } })
    },
  )
}

test fail_when_setting_lower_start() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, start: datum.start - 1 } },
          )
    },
  )
}

test fail_when_setting_higher_start() {
  !validate(
    fn(obond) {
      obond
        |> set_bond_datum(
            fn(datum) { BondDatum { ..datum, start: datum.start + 1 } },
          )
    },
  )
}

// Assets
test fail_when_withdraw_ada() {
  !validate(
    fn(obond) {
      obond
        |> add_asset(value.ada_policy_id, value.ada_asset_name, -1)
    },
  )
}

test fail_when_steal_nft() fail {
  !validate(
    fn(obond) {
      Output {
        ..obond,
        value: value.from_lovelace(
          obond.value
            |> value.quantity_of(value.ada_policy_id, value.ada_asset_name),
        ),
      }
    },
  )
}

test fail_when_setting_incorrect_nft_policy() fail {
  !validate(
    fn(obond) {
      let datum = get_bond_datum(obond)
      obond
        |> add_asset(bond_nft_pid, datum.token_name, -1)
        |> add_asset("other_pid", datum.token_name, 1)
    },
  )
}

test fail_when_setting_incorrect_nft_name() fail {
  !validate(
    fn(obond) {
      let datum = get_bond_datum(obond)
      obond
        |> add_asset(bond_nft_pid, datum.token_name, -1)
        |> add_asset(bond_nft_pid, "other_name", 1)
    },
  )
}

test fail_when_changing_stake_key_at_maturity_date() {
  let platform_cfg = build_platform_cfg()
  let bond_issue_cfg =
    BondIssueConfig {
      slot: get_slot_config_network_mainnet(),
      epoch: get_epoch_config_mainnet(),
      basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
      platform: platform_cfg,
    }

  let bond_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1_000_000_000) |> pvalue.from_value,
      bond_symbol: "bond_symbol_1",
      token_name: "bond_name_1",
      bond_amount: 100,
      fee: 500,
      borrower: "borrower_1",
      start: 450,
      buffer: platform_cfg.min_buffer,
      duration: platform_cfg.min_duration,
    }
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_sbond_1"), 0),
      output: build_bond_output(bond_datum, "owner"),
    }
  expect (tx, [bond]) =
    build_tx(
      [(sbond, [sbond.output |> set_stake_credential(Some("new_owner"))])],
    )
  let end_poch_start_at_posix_time =
    relative_epoch_to_posix_time_start(
      bond_issue_cfg.epoch.epoch_boundary_as_epoch + bond_datum.duration + bond_datum.start,
      bond_issue_cfg.epoch,
    )
  !change_stake_key.constraint(
    cfg: bond_issue_cfg,
    tx: Transaction {
      ..tx,
      validity_range: interval.between(
        end_poch_start_at_posix_time,
        end_poch_start_at_posix_time + 30_000,
      ),
    },
    sbond: bond,
    sbond_dt: get_bond_datum(bond),
    bond_nft_pid: bond_nft_pid,
  )
}

test fail_when_changing_stake_key_after_maturity_date() {
  let platform_cfg = build_platform_cfg()
  let bond_issue_cfg =
    BondIssueConfig {
      slot: get_slot_config_network_mainnet(),
      epoch: get_epoch_config_mainnet(),
      basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
      platform: platform_cfg,
    }

  let bond_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada) |> pvalue.from_value,
      bond_symbol: "bond_symbol_1",
      token_name: "bond_name_1",
      bond_amount: 100,
      fee: 500,
      borrower: "borrower_1",
      start: 450,
      buffer: platform_cfg.min_buffer,
      duration: platform_cfg.min_duration,
    }
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_sbond_1"), 0),
      output: build_bond_output(bond_datum, "owner"),
    }
  expect (tx, [bond]) =
    build_tx(
      [(sbond, [sbond.output |> set_stake_credential(Some("new_owner"))])],
    )
  let end_poch_start_at_posix_time =
    relative_epoch_to_posix_time_start(
      1 + bond_issue_cfg.epoch.epoch_boundary_as_epoch + bond_datum.duration + bond_datum.start,
      bond_issue_cfg.epoch,
    )
  !change_stake_key.constraint(
    cfg: bond_issue_cfg,
    tx: Transaction {
      ..tx,
      validity_range: interval.between(
        end_poch_start_at_posix_time,
        end_poch_start_at_posix_time + 30_000,
      ),
    },
    sbond: bond,
    sbond_dt: get_bond_datum(bond),
    bond_nft_pid: bond_nft_pid,
  )
}

test fail_when_changing_stake_key_after_redeem_fee() {
  let platform_cfg = build_platform_cfg()
  let bond_issue_cfg =
    BondIssueConfig {
      slot: get_slot_config_network_mainnet(),
      epoch: get_epoch_config_mainnet(),
      basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
      platform: platform_cfg,
    }

  let bond_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(30 * ada) |> pvalue.from_value,
      bond_symbol: "bond_symbol_1",
      token_name: "bond_name_1",
      bond_amount: 100,
      fee: 0,
      borrower: "borrower_1",
      start: 450,
      buffer: 20,
      duration: platform_cfg.min_duration,
    }
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_sbond_1"), 0),
      output: build_bond_output(bond_datum, "owner")
        |> add_asset(ada_policy_id, ada_asset_name, -1500 * ada),
    }
  expect (tx, [bond]) =
    build_tx(
      [(sbond, [sbond.output |> set_stake_credential(Some("new_owner"))])],
    )
  !change_stake_key.constraint(
    cfg: bond_issue_cfg,
    tx: tx,
    sbond: bond,
    sbond_dt: get_bond_datum(bond),
    bond_nft_pid: bond_nft_pid,
  )
}
