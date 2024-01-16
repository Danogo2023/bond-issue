use aiken/bytearray
use aiken/interval
use aiken/list
use aiken/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
  TransactionId,
}
use aiken/transaction/credential.{
  Address, Inline, ScriptCredential, VerificationKeyCredential, from_script,
  from_verification_key, with_delegation_key,
}
use aiken/transaction/value.{ada_asset_name, ada_policy_id}
use bond_issue/types.{BondDatum, BondIssueConfig, PlatformConfig}
use borrow_position/redeem_fee
use common/time.{
  BasisPoints, get_epoch_config_mainnet, get_slot_config_network_mainnet,
  relative_epoch_to_posix_time_start,
}

const nft_pid = "nft_pid"

const bond_script_hash = "bond_script_hash"

const ada = 1_000_000

fn get_default_stake_cred() {
  Inline(VerificationKeyCredential("protocol_public_key"))
}

fn build_cfg() {
  BondIssueConfig {
    slot: get_slot_config_network_mainnet(),
    epoch: get_epoch_config_mainnet(),
    basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
    platform: PlatformConfig {
      bond_face_value: 100 * ada,
      fee: 500,
      fee_addr: from_verification_key("fee_addr"),
      tx_ttl: 1 * 60,
      min_buffer: 6,
      prepaid_plus: 3,
      min_requested: 100,
      min_apr: 200,
      min_duration: 6,
    },
  }
}

fn get_bond_datum(self: Output) {
  expect InlineDatum(datum) = self.datum
  expect dtm: BondDatum = datum
  dtm
}

fn withdraw_fee(self: Output) {
  let cfg = build_cfg()
  let dtm = get_bond_datum(self)
  let locked_amt = self.value |> value.lovelace_of
  let principal = dtm.bond_amount * cfg.platform.bond_face_value
  let interest_paid = locked_amt - principal
  let fee = interest_paid * dtm.fee / cfg.basis.base
  (
    Output {
      ..self,
      value: self.value |> value.add(ada_policy_id, ada_asset_name, -fee),
      datum: InlineDatum(BondDatum { ..dtm, fee: 0 }),
    },
    fee,
  )
}

fn build_tx(input: Input) {
  let cfg = build_cfg()
  let txn_fee = 600_000
  let arbitrary_input =
    Input {
      output_reference: OutputReference(TransactionId("submitter_tx"), 0),
      output: Output {
        address: from_verification_key("arbitrary_public_key"),
        value: value.from_lovelace(1233411),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let (obond, fee) = input.output |> withdraw_fee
  Transaction {
    ..transaction.placeholder(),
    validity_range: {
      let cfg = build_cfg()
      let bond_datum = get_bond_datum(input.output)
      let end_poch_start_at_posix_time =
        relative_epoch_to_posix_time_start(
          cfg.epoch.epoch_boundary_as_epoch + bond_datum.duration + bond_datum.start,
          cfg.epoch,
        )
      interval.between(
        end_poch_start_at_posix_time,
        end_poch_start_at_posix_time + 30_000,
      )
    },
    inputs: [input, arbitrary_input],
    outputs: [
      obond,
      Output {
        ..arbitrary_input.output,
        value: arbitrary_input.output.value
          |> value.add(ada_policy_id, ada_asset_name, -txn_fee),
      },
      Output {
        value: value.from_lovelace(fee),
        address: cfg.platform.fee_addr,
        datum: NoDatum,
        reference_script: None,
      },
    ],
  }
}

fn get_bond_like(bond_amt: Int, prepaid: Int, seed: ByteArray) {
  let reward_per_epoch = 1 * ada
  Output {
    value: value.from_lovelace(
      bond_amt * 100 * ada + reward_per_epoch * prepaid,
    )
      |> value.add(nft_pid, bytearray.concat("bond_name", seed), 1),
    address: from_script(bond_script_hash)
      |> with_delegation_key("owner_stake_key"),
    datum: InlineDatum(
      BondDatum {
        epo_rewards: value.from_lovelace(reward_per_epoch),
        duration: 36,
        bond_symbol: nft_pid,
        token_name: bytearray.concat("bond_name", seed),
        bond_amount: bond_amt,
        buffer: 5,
        fee: 500,
        borrower: bytearray.concat("borrower", seed),
        start: 450,
      },
    ),
    reference_script: None,
  }
}

fn with_obond(self: Transaction, descriptor: fn(Output) -> Output) {
  Transaction {
    ..self,
    outputs: list.map(
      self.outputs,
      fn(output) {
        if
        output.address.payment_credential == ScriptCredential(bond_script_hash){
        
          descriptor(output)
        } else {
          output
        }
      },
    ),
  }
}

test succ_when_redeeming_fee_correctly() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx = build_tx(sbond)
  redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test succ_when_changing_stake_key_addtionally() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               address: Address {
                 ..obond.address,
                 stake_credential: Some(get_default_stake_cred()),
               },
             }
           },
         )
  redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_redeeming_fee_before_maturity() {
  let cfg = build_cfg()
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx = build_tx(sbond)
  !redeem_fee.spending(
    cfg,
    Transaction {
      ..tx,
      validity_range: {
        let tx_at = relative_epoch_to_posix_time_start(500, cfg.epoch)
        interval.between(tx_at, tx_at + 30_000)
      },
    },
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_incorrect_bond_symbol() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..get_bond_datum(obond), bond_symbol: "unknown" },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_incorrect_token_name() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..get_bond_datum(obond), token_name: "unknown" },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_incorrect_borrower() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..get_bond_datum(obond), borrower: "unknown" },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_lower_epo_rewards() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum {
                   ..dtm,
                   epo_rewards: dtm.epo_rewards
                     |> value.add(ada_policy_id, ada_asset_name, -1),
                 },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_higher_epo_rewards() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum {
                   ..dtm,
                   epo_rewards: dtm.epo_rewards
                     |> value.add(ada_policy_id, ada_asset_name, 1),
                 },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_lower_duration() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..dtm, duration: dtm.duration - 1 },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_higher_duration() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..dtm, duration: dtm.duration + 1 },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_lower_bond_amount() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..dtm, bond_amount: dtm.bond_amount - 1 },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_higher_bond_amount() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(
                 BondDatum { ..dtm, bond_amount: dtm.bond_amount + 1 },
               ),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_lower_buffer() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(BondDatum { ..dtm, buffer: dtm.buffer - 1 }),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_higher_buffer() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(BondDatum { ..dtm, buffer: dtm.buffer + 1 }),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_lower_start() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(BondDatum { ..dtm, start: dtm.start - 1 }),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_higher_start() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(BondDatum { ..dtm, start: dtm.start + 1 }),
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_negative_fee() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(BondDatum { ..dtm, fee: dtm.fee - 1 }),
             }
           },
         )

  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_positive_fee() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             let dtm = get_bond_datum(obond)
             Output {
               ..obond,
               datum: InlineDatum(BondDatum { ..dtm, fee: dtm.fee + 1 }),
             }
           },
         )

  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_incorrect_continuous_value() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               value: obond.value
                 |> value.add(ada_policy_id, ada_asset_name, -1),
             }
           },
         )

  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_incorrect_bond_stake_key() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               address: Address {
                 ..obond.address,
                 stake_credential: Some(
                   Inline(VerificationKeyCredential("unkown")),
                 ),
               },
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

test fail_when_setting_bond_stake_key_to_none() {
  let sbond =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let tx =
    build_tx(sbond)
      |> with_obond(
           fn(obond) {
             Output {
               ..obond,
               address: Address { ..obond.address, stake_credential: None },
             }
           },
         )
  !redeem_fee.spending(
    build_cfg(),
    tx,
    sbond.output,
    sbond.output.address,
    get_bond_datum(sbond.output),
    nft_pid,
    get_default_stake_cred(),
  )
}

// Attempting redeem fee of multiple bonds, first fee goes to protocol 
// and the rest go to arbitrary address
test fail_when_attempting_multiple_bonds_satisfaction() fail {
  let sbond1 =
    Input {
      output_reference: OutputReference(TransactionId("tx_1"), 1),
      output: get_bond_like(bond_amt: 100, prepaid: 5, seed: "1"),
    }
  let sbond2 =
    Input {
      output_reference: OutputReference(TransactionId("tx_2"), 0),
      output: get_bond_like(bond_amt: 200, prepaid: 5, seed: "2"),
    }
  let cfg = build_cfg()
  let txn_fee = 600_000
  let arbitrary_input =
    Input {
      output_reference: OutputReference(TransactionId("submitter_tx"), 0),
      output: Output {
        address: from_verification_key("arbitrary_public_key"),
        value: value.from_lovelace(1233411),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let (obond1, fee1) = sbond1.output |> withdraw_fee
  let (obond2, fee2) = sbond2.output |> withdraw_fee

  let tx =
    Transaction {
      ..transaction.placeholder(),
      validity_range: {
        let cfg = build_cfg()
        let bond_datum = get_bond_datum(sbond1.output)
        let end_poch_start_at_posix_time =
          relative_epoch_to_posix_time_start(
            cfg.epoch.epoch_boundary_as_epoch + bond_datum.duration + bond_datum.start,
            cfg.epoch,
          )
        interval.between(
          end_poch_start_at_posix_time,
          end_poch_start_at_posix_time + 30_000,
        )
      },
      inputs: [sbond1, sbond2, arbitrary_input],
      outputs: [
        obond1,
        obond2,
        Output {
          ..arbitrary_input.output,
          value: arbitrary_input.output.value
            |> value.add(ada_policy_id, ada_asset_name, -txn_fee + fee2),
        },
        Output {
          value: value.from_lovelace(fee1),
          address: cfg.platform.fee_addr,
          datum: NoDatum,
          reference_script: None,
        },
      ],
    }
  !and {
    redeem_fee.spending(
      build_cfg(),
      tx,
      sbond1.output,
      sbond1.output.address,
      get_bond_datum(sbond1.output),
      nft_pid,
      get_default_stake_cred(),
    ),
    redeem_fee.spending(
      build_cfg(),
      tx,
      sbond2.output,
      sbond2.output.address,
      get_bond_datum(sbond2.output),
      nft_pid,
      get_default_stake_cred(),
    ),
  }
}
