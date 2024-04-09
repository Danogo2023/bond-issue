use aiken/bytearray
use aiken/cbor
use aiken/dict
use aiken/interval
use aiken/math.{min}
use aiken/string
use aiken/transaction.{
  InlineDatum, Input, Mint, NoDatum, Output, OutputReference, ScriptPurpose,
  Transaction, TransactionId,
}
use aiken/transaction/credential
use aiken/transaction/value.{ada_asset_name, ada_policy_id}
use bond_issue/types.{BondDatum, BondIssueConfig, PlatformConfig}
use borrow_position/mint_bond
use common/fixture.{get_epoch_config_mainnet}
use common/hash_out_refs.{hash_out_ref}
use common/pvalue
use common/time.{BasisPoints,
  get_current_epoch, get_slot_config_network_mainnet}
use issue_bond/types.{BondCreate, RequestCreate} as issue_bond_types
use issue_bond/utils.{log, mint_nft}
use protocol_params/types.{ProtocolParams} as protocol_params_types
use stringify

// ============== Fixtures ===============
const ada = 1_000_000

fn get_tx_validity_range() {
  interval.between(1702616373000, 1702616373000 + 30_000)
}

fn build_protocol_params() {
  ProtocolParams {
    bond_nft_pid: "bond_nft_pid",
    bond_skh: "bond_skh",
    bond_token_pid: "bond_token_pid",
    borrower_pid: "borrower_pid",
    borrow_request_pid: "borrow_request_pid",
    borrow_request_skh: "borrow_request_skh",
  }
}

fn build_cfg() {
  BondIssueConfig {
    slot: get_slot_config_network_mainnet(),
    epoch: get_epoch_config_mainnet(),
    basis: BasisPoints { base: 10_000, min: 1, max: 9_999 },
    platform: PlatformConfig {
      bond_face_value: 100 * ada,
      fee: 500,
      fee_addr: credential.from_verification_key("fee_addr"),
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

fn build_protocol_params_input() {
  Input {
    output_reference: OutputReference(TransactionId("tx_protocol_params_0"), 1),
    output: Output {
      value: value.from_lovelace(2 * ada),
      address: credential.from_script("always_false_script_hash"),
      datum: InlineDatum(build_protocol_params()),
      reference_script: None,
    },
  }
}

fn script_purpose_compare(a: ScriptPurpose, b: ScriptPurpose) {
  bytearray.compare(
    cbor.diagnostic(a) |> string.to_bytearray,
    cbor.diagnostic(b) |> string.to_bytearray,
  )
}

fn fail_if_false(predicate: Bool) {
  if predicate {
    True
  } else {
    fail @"expected True but got False"
  }
}

pub fn log_tx(self: Transaction) -> Transaction {
  log(self, stringify.tx)
}

// ============== Tests ===============

test succ_when_minting_a_bond() {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: pvalue.from_value(epo_rewards_assets),
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test succ_when_minting_multiple_bonds() {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_script("script_hash"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_2_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_2_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_script("script_hash"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let bond_2_nft_name = hash_out_ref(lender_2_input.output_reference)
  let bond_2_token_name = bond_2_nft_name
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: pvalue.from_value(epo_rewards_assets),
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, bond_datum.bond_amount),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_2_nft_output, bond_2_datum) = {
    let PlatformConfig {
      min_apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let apr = min_apr + 10
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: pvalue.from_value(epo_rewards_assets),
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_2_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_2_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let bond_2_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_2_token_name, bond_2_datum.bond_amount),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_token_pid, bond_2_token_name, bond_2_datum.bond_amount)
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(bond_nft_pid, bond_2_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, lender_2_input, borrower_input],
      outputs: [
        bond_token_output,
        bond_2_token_output,
        bond_nft_output,
        bond_2_nft_output,
        borrower_output,
      ],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_minting_invalid_borrower_name() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = "target_name"
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: pvalue.from_value(epo_rewards_assets),
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  !and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_minting_invalid_bond_nft_name() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = "target_name"
  let bond_token_name = hash_out_ref(lender_input.output_reference)
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: pvalue.from_value(epo_rewards_assets),
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_minting_invalid_bond_token_name() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = "target_name"
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: pvalue.from_value(epo_rewards_assets),
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_doesnt_mint_bond_nft() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_doesnt_mint_bond_token() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, _) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.zero()
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_setting_invalid_bond_symbol() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: "target_policy_id",
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_setting_invalid_token_name() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: "target_name",
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_setting_lower_fee() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee: fee - 1,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_setting_start_in_past() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start: start - 1,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_bond_utxo_doest_hold_nft() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_locked_assets_doesnt_meet_datum() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      min(buffer + prepaid_plus, duration) * value.lovelace_of(
        epo_rewards_assets,
      )
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(ada_policy_id, ada_asset_name, -1)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_setting_lower_min_buffer() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let buffer = min_buffer - 1
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch + 1
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_setting_lower_min_duration() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let duration = min_duration - 1
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

// Mint 2 bond_nft and corresponding bond_token, but one of escrow has no fund
test fail_when_attempt_double_satisfaction_on_bond_nft() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_script("script_hash"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_2_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_2_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_script("script_hash"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let bond_2_nft_name = hash_out_ref(lender_2_input.output_reference)
  let bond_2_token_name = bond_2_nft_name
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, bond_datum.bond_amount),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_2_nft_output, bond_2_datum) = {
    let PlatformConfig {
      min_apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      ..
    } = cfg.platform
    let apr = min_apr + 10
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    // let required_premium =
    //   ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_2_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(2 * ada) // <- no fund
          |> value.add(bond_nft_pid, bond_2_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let bond_2_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_2_token_name, bond_2_datum.bond_amount),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_token_pid, bond_2_token_name, bond_2_datum.bond_amount)
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(bond_nft_pid, bond_2_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, lender_2_input, borrower_input],
      outputs: [
        bond_token_output,
        bond_2_token_output,
        bond_nft_output,
        bond_2_nft_output,
        borrower_output,
      ],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_minting_exceeded_bond_token() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, bond_datum.bond_amount + 1),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount + 1,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}

test fail_when_minting_exceeded_bond_nft() fail {
  let cfg = build_cfg()
  let ProtocolParams {
    bond_skh: bond_nft_pid,
    bond_token_pid,
    borrower_pid,
    ..
  } = build_protocol_params()
  let t = transaction.placeholder()
  let protocol_params_input = build_protocol_params_input()
  let borrower_input =
    Input {
      output_reference: OutputReference(TransactionId("borrower_tx_0"), 0),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("borrower_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let lender_input =
    Input {
      output_reference: OutputReference(TransactionId("lender_tx_0"), 1),
      output: Output {
        value: value.from_lovelace(1000 * ada),
        address: credential.from_verification_key("lender_public_key"),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let borrower_name = hash_out_ref(borrower_input.output_reference)
  let bond_nft_name = hash_out_ref(lender_input.output_reference)
  let bond_token_name = bond_nft_name
  let borrower_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_nft_pid, bond_nft_name, 1)
        |> value.add(borrower_pid, borrower_name, 1),
      address: borrower_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let bond_token_output =
    Output {
      value: value.from_lovelace(2 * ada)
        |> value.add(bond_token_pid, bond_token_name, 10),
      address: lender_input.output.address,
      datum: NoDatum,
      reference_script: None,
    }
  let (bond_nft_output, bond_datum) = {
    let PlatformConfig {
      min_apr: apr,
      min_duration: duration,
      min_buffer: buffer,
      fee,
      bond_face_value,
      prepaid_plus,
      ..
    } = cfg.platform
    let bond_amount = 10
    let principal = bond_amount * bond_face_value
    let epo_rewards_assets =
      principal * apr / cfg.basis.base / cfg.epoch.year_to_epoch
        |> value.from_lovelace
    let required_premium =
      ( buffer + prepaid_plus ) * value.lovelace_of(epo_rewards_assets)
    let current_epoch = get_current_epoch(get_tx_validity_range(), cfg.epoch)
    let start = current_epoch - cfg.epoch.epoch_boundary_as_epoch
    let bond_datum =
      BondDatum {
        epo_rewards: epo_rewards_assets |> pvalue.from_value,
        duration,
        bond_symbol: bond_token_pid,
        token_name: bond_token_name,
        buffer,
        fee,
        borrower: borrower_name,
        start,
        bond_amount,
      }
    (
      Output {
        value: value.from_lovelace(principal + required_premium)
          |> value.add(bond_nft_pid, bond_nft_name, 1),
        address: credential.from_script(bond_nft_pid)
          |> credential.with_delegation_key("borrower_stake_key"),
        datum: InlineDatum(bond_datum),
        reference_script: None,
      },
      bond_datum,
    )
  }
  let tx =
    Transaction {
      ..t,
      mint: value.from_asset(
        bond_token_pid,
        bond_token_name,
        bond_datum.bond_amount,
      )
        |> value.add(bond_nft_pid, bond_nft_name, 2)
        |> value.add(borrower_pid, borrower_name, 1)
        |> value.to_minted_value,
      validity_range: get_tx_validity_range(),
      redeemers: t.redeemers
        |> dict.insert(Mint(bond_token_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(bond_nft_pid), BondCreate, script_purpose_compare)
        |> dict.insert(Mint(borrower_pid), RequestCreate, script_purpose_compare),
      reference_inputs: [protocol_params_input],
      inputs: [lender_input, borrower_input],
      outputs: [bond_token_output, bond_nft_output, borrower_output],
    }
  and {
    // mint bond_token + mint bond_nft invoking the same function
    mint_bond.create(cfg, tx, bond_nft_pid, bond_token_pid),
    mint_nft(tx, borrower_pid),
  } |> fail_if_false
}
