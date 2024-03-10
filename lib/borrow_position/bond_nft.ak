use aiken/bytearray
use aiken/dict
use aiken/list
use aiken/option
use aiken/transaction.{InlineDatum, Transaction}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig, RequestDatum}
use common/hash_out_refs.{hash_out_ref_salt}
use common/time.{get_current_epoch_with_ttl}
use issue_bond/utils.{
  bond_asset_valid, check_output_request_base, get_burn_nft_names,
  get_input_by_nft_names, get_output_by_nft_names,
}

pub fn burning_bond_redeem(tx: Transaction, bond_nft_pid: PolicyId) -> Bool {
  burning_valid(tx, bond_nft_pid)
}

pub fn burning_force_redeem(tx: Transaction, bond_nft_pid: PolicyId) -> Bool {
  burning_valid(tx, bond_nft_pid)
}

fn burning_valid(tx: Transaction, bond_nft_pid: PolicyId) -> Bool {
  let burn_names = get_burn_nft_names(tx, bond_nft_pid)
  let ibond = get_input_by_nft_names(tx, burn_names, bond_nft_pid)
  let obond = get_output_by_nft_names(tx, burn_names, bond_nft_pid)
  and {
    (list.length(burn_names) > 0)?,
    (list.length(ibond) == list.length(burn_names))?,
    (list.length(obond) == 0)?,
  }
}

pub fn minting(
  cfg: BondIssueConfig,
  tx: Transaction,
  bond_nft_pid: PolicyId,
  req_nft_pid: PolicyId,
) -> Bool {
  let bond_nft_mint =
    value.tokens(value.from_minted_value(tx.mint), bond_nft_pid)
  let (bond_name_mint_valid, bond_name_mint_valid_count) =
    dict.foldr(
      bond_nft_mint,
      ([], 0),
      fn(n, q, z) {
        if (q == 1)? {
          ([n, ..z.1st], z.2nd + 1)
        } else {
          z
        }
      },
    )
  if (dict.size(bond_nft_mint) == bond_name_mint_valid_count)? {
    let req_pk = ScriptCredential(req_nft_pid)
    let (bond_inputs_valid, bond_name_inputs_valid_count) =
      list.foldr(
        tx.inputs,
        (dict.new(), 0),
        fn(i, z) {
          let req_nft_tokens = value.tokens(i.output.value, req_nft_pid)
          if and {
            i.output.address.payment_credential == req_pk,
            dict.size(req_nft_tokens) == 1,
          } {
            expect sreq_dt: RequestDatum =
              when i.output.datum is {
                InlineDatum(d) -> d
                _ -> fail @"only supports InlineDatum for borrow request"
              }
            if and {
              //
              (i.output.address.stake_credential != None)?,
              check_output_request_base(cfg, i.output, sreq_dt)?,
              (sreq_dt.requested > sreq_dt.issued)?,
              (sreq_dt.issued >= 0)?,
              ((
                dict.get(req_nft_tokens, sreq_dt.borrower) |> option.or_else(0)
              ) == 1)?,
            } {
              let bond_name =
                hash_out_ref_salt(i.output_reference, sreq_dt.borrower)
              if !dict.has_key(z.1st, bond_name) {
                (
                  dict.insert(
                    z.1st,
                    bond_name,
                    (i.output.address.stake_credential, sreq_dt),
                    bytearray.compare,
                  ),
                  z.2nd + 1,
                )
              } else {
                fail @"borrow request input must be unique"
              }
            } else {
              fail
            }
          } else {
            z
          }
        },
      )
    let bond_name_inputs_valid = dict.keys(bond_inputs_valid)
    and {
      (bond_name_inputs_valid_count == bond_name_mint_valid_count)?,
      (list.difference(bond_name_inputs_valid, bond_name_mint_valid) == [])?,
      {
        let epoch_curr =
          get_current_epoch_with_ttl(
            tx.validity_range,
            cfg.epoch,
            cfg.platform.tx_ttl,
            cfg.slot.slot_length,
          )
        let bond_pk = ScriptCredential(bond_nft_pid)
        let (_, bond_name_outputs_valid_count) =
          list.foldr(
            tx.outputs,
            ([], 0),
            fn(o, z) {
              let bond_nft_tokens = value.tokens(o.value, bond_nft_pid)
              if and {
                o.address.payment_credential == bond_pk,
                dict.size(bond_nft_tokens) == 1,
              } {
                expect obond_dt: BondDatum =
                  when o.datum is {
                    InlineDatum(d) -> d
                    _ ->
                      fail @"borrow_position/bond_nft.minting: only supports InlineDatum for bond"
                  }
                if !list.has(z.1st, obond_dt.token_name) {
                  expect Some((iskh, sreq_dt)) =
                    dict.get(bond_inputs_valid, obond_dt.token_name)
                  if and {
                    (obond_dt.borrower == sreq_dt.borrower)?,
                    (o.address.stake_credential == iskh)?,
                    ((
                      dict.get(bond_nft_tokens, obond_dt.token_name)
                        |> option.or_else(0)
                    ) == 1)?,
                    //
                    list.has(bond_name_inputs_valid, obond_dt.token_name)?,
                    //
                    (obond_dt.duration >= cfg.platform.min_duration)?,
                    (obond_dt.buffer >= cfg.platform.min_buffer)?,
                    (obond_dt.fee >= cfg.platform.fee)?,
                    (obond_dt.bond_amount > 0)?,
                    (obond_dt.start == epoch_curr - cfg.epoch.epoch_boundary_as_epoch)?,
                  } {
                    let obond_principal =
                      obond_dt.bond_amount * cfg.platform.bond_face_value
                    let obond_epo_rewards =
                      obond_principal * sreq_dt.apr / cfg.basis.base / cfg.epoch.year_to_epoch
                    let required_premium = obond_epo_rewards * sreq_dt.prepaid
                    if and {
                      (value.lovelace_of(obond_dt.epo_rewards) == obond_epo_rewards)?,
                      bond_asset_valid(
                        bond_nft_pid,
                        obond_dt,
                        o,
                        obond_principal + required_premium,
                      ),
                    } {
                      ([obond_dt.token_name, ..z.1st], z.2nd + 1)
                    } else {
                      fail
                    }
                  } else {
                    fail
                  }
                } else {
                  fail @"bond utxo output must be unique"
                }
              } else {
                z
              }
            },
          )
        (bond_name_outputs_valid_count == bond_name_inputs_valid_count)?
      },
    }
  } else {
    fail
  }
}
