use aiken/interval.{entirely_between}
use aiken/transaction.{
  InlineDatum, Input, Mint, NoDatum, Output, OutputReference, Spend,
  TransactionId,
}
use aiken/transaction/credential.{
  from_script, from_verification_key, with_delegation_key,
}
use aiken/transaction/value.{ada_asset_name, ada_policy_id}
use bond_issue/types.{BondDatum, BondIssueConfig, PlatformConfig}
use borrow_position/redeem_force
use common/pvalue
use common/time.{
  BasisPoints, get_epoch_config_mainnet, get_slot_config_network_mainnet,
  relative_epoch_to_posix_time_start,
}
use issue_bond/types.{RedeemFee, RedeemForce} as issue_bond_types
use tx_builder

const bond_nft_pid = "bond_nft_pid"

const bond_token_pid = "bond_token_pid"

const bond_skh = "bond_nft_skh"

const ada = 1_000_000

const redeem_over_epochs = 73

fn get_config() {
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
      min_ada: 2 * ada,
    },
  }
}

test succ_when_redeem_escrow_at_deadline() {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, escrow_datum.token_name, -1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test succ_when_redeem_escrow_after_deadline() {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let delay_epoch = 1
            let epoch_deadline =
              delay_epoch + cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, escrow_datum.token_name, -1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_redeem_escrow_before_deadline() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch) - 1
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, escrow_datum.token_name, -1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_doesnt_burn_bond_nft() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada)
        |> value.add(bond_nft_pid, escrow_datum.token_name, 1),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_leak_funds() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let leak_amount = 1
  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) - leak_amount
        |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada + leak_amount)
        |> value.add(bond_nft_pid, escrow_datum.token_name, 1),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_redeem_multiple_bonds() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }
  let escrow_input_2 =
    Input {
      output_reference: OutputReference(TransactionId("tx_01"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(
          BondDatum { ..escrow_datum, token_name: "token_name_2" },
        ),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let leak_amount = 1
  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) - leak_amount
        |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada + leak_amount)
        |> value.add(bond_nft_pid, escrow_datum.token_name, 1),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(escrow_input_2)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

/// Attempt to break constraints by using a minting redeemer other than RedeemForce.
/// We assume that the minting redeemer always pass at spending redeemer perspective
test fail_when_attempt_other_redeemer_attack() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(bond_nft_pid, escrow_datum.token_name, 1)
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemFee)

  and {
    redeem_force.spend_bond(tx, bond_nft_pid),
    True,
  }
}

test fail_when_outputs_have_more_than_1_fee_output() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, escrow_datum.token_name, -1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_minting_addtionally_bond_nft() fail {
  let target_bond_name = "target_bond_name"
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(bond_nft_pid, target_bond_name, 1)
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, escrow_datum.token_name, -1)
      |> tx_builder.mint_asset(bond_nft_pid, target_bond_name, 1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

/// Payer doesn't burn bond nft actually, his purpose is
/// to steal the escrow NFT. He still pays for the protocol
/// funds but duplicate the NFT, intends to bypass minting check
test fail_when_doesnt_burn_bond_nft_but_mint() fail {
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(bond_nft_pid, escrow_datum.token_name, 2)
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, escrow_datum.token_name, 1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_burn_incorrect_bond_nft_name() fail {
  let other_token_name = "other_token_name"
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada)
          |> value.add(bond_nft_pid, other_token_name, 1),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(bond_nft_pid, escrow_datum.token_name, 1)
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(bond_nft_pid, other_token_name, -1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(bond_nft_pid), RedeemForce)

  and {
    redeem_force.burn_bond_nft(
      cfg,
      tx,
      bond_nft_pid,
      bond_skh,
      redeem_over_epochs,
    ),
    redeem_force.spend_bond(tx, bond_nft_pid),
  }
}

test fail_when_burn_incorrect_bond_policy() fail {
  let other_policy = "other_token_name"
  let cfg = get_config()
  let escrow_datum =
    BondDatum {
      epo_rewards: value.from_lovelace(1 * ada)
        |> pvalue.from_value,
      duration: 36,
      bond_symbol: bond_token_pid,
      token_name: "token_name",
      bond_amount: 100,
      buffer: 5,
      fee: 500,
      borrower: "borrower",
      start: 450,
    }
  let escrow_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_00"), 1),
      output: Output {
        value: value.from_lovelace(100 * ada),
        address: from_script(bond_skh) |> with_delegation_key("any"),
        datum: InlineDatum(escrow_datum),
        reference_script: None,
      },
    }

  let payer_input =
    Input {
      output_reference: OutputReference(TransactionId("tx_payer_00"), 1),
      output: Output {
        address: from_verification_key("any_vkh")
          |> with_delegation_key("any_sk"),
        value: value.from_lovelace(10 * ada)
          |> value.add(other_policy, escrow_datum.token_name, 1),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let protocol_output =
    Output {
      address: cfg.platform.fee_addr,
      value: value.lovelace_of(escrow_input.output.value) |> value.from_lovelace,
      datum: NoDatum,
      reference_script: None,
    }

  let payer_output =
    Output {
      ..payer_input.output,
      value: payer_input.output.value
        |> value.add(bond_nft_pid, escrow_datum.token_name, 1)
        |> value.add(ada_policy_id, ada_asset_name, -1 * ada),
    }
  let tx =
    tx_builder.new()
      |> tx_builder.set_validity_range(
          {
            let epoch_deadline =
              cfg.epoch.epoch_boundary_as_epoch + escrow_datum.start + escrow_datum.duration + redeem_over_epochs
            let valid_from =
              relative_epoch_to_posix_time_start(epoch_deadline, cfg.epoch)
            let valid_to = valid_from + 60 * cfg.slot.slot_length
            entirely_between(valid_from, valid_to)
          },
        )
      |> tx_builder.mint_asset(other_policy, escrow_datum.token_name, -1)
      |> tx_builder.add_input(escrow_input)
      |> tx_builder.add_input(payer_input)
      |> tx_builder.add_output(protocol_output)
      |> tx_builder.add_output(payer_output)
      |> tx_builder.add_redeemer(Spend(escrow_input.output_reference), RedeemForce)
      |> tx_builder.add_redeemer(Mint(other_policy), RedeemForce)

  and {
    redeem_force.spend_bond(tx, bond_nft_pid),
    True,
  }
}
