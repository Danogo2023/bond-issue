use aiken/bytearray
use aiken/dict.{Dict}
use aiken/list
use aiken/math
use aiken/option
use aiken/transaction.{InlineDatum, Mint, Spend, Transaction}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{AssetName, PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig}
use common/hash_out_refs.{hash_out_ref}
use common/pvalue
use common/time.{get_current_epoch_with_ttl}
use issue_bond/types.{BondCreate,
  BondIssueAction, BondRedeem} as issue_bond_types
use issue_bond/utils.{bond_asset_valid}

fn get_bond_token_burn(
  assets: Dict<AssetName, Int>,
  zero: (Dict<AssetName, Int>, Int),
) -> (Dict<AssetName, Int>, Int) {
  dict.foldr(
    assets,
    zero,
    fn(n, q, z) {
      if (q < 0)? {
        (dict.insert(z.1st, n, q, bytearray.compare), z.2nd + 1)
      } else {
        fail @"must burn bond token only"
      }
    },
  )
}

// Burning a bond_nft requires burning all associated bond tokens in circulation,
// the correspoding redeemer of bond token guaranteed that the bond must be burned
// correctly. So we just require appearance of the bond token redeeemer
pub fn burn_bond_nft_with_bond_token_redeemer(
  tx: Transaction,
  bond_token_pid: PolicyId,
) -> Bool {
  expect Some(redeemer) = dict.get(tx.redeemers, Mint(bond_token_pid))
  expect bond_token_burn: BondIssueAction = redeemer
  (bond_token_burn == BondRedeem)?
}

// Since burning bond_nft redeemer rely on this validation, we prevent minting bond tokens in this transaction.
// The transaction must spend associated bond escrow with BondRedeem redeemer to unlock funds.
// The bond_amount state must remain correctly (reflect burned amount)
// The bond_amount avaiable must not less than actual burned amount 
pub fn burn_bond_token(
  tx: Transaction,
  bond_nft_pid: PolicyId,
  bond_token_pid: PolicyId,
) -> Bool {
  let tx_mint_value = value.from_minted_value(tx.mint)
  let (bond_token_burn_valid, bond_token_burn_valid_name_count) =
    get_bond_token_burn(
      tx_mint_value |> value.tokens(bond_token_pid),
      (dict.new(), 0),
    )
  let bond_pk = ScriptCredential(bond_nft_pid)
  let (
    bond_token_burn_valid_name_inputs,
    bond_token_burn_valid_name_inputs_count,
    bond_token_burn_all_valid_inputs,
    bond_token_burn_all_valid_inputs_count,
  ) =
    list.foldr(
      tx.inputs,
      ([], 0, [], 0),
      fn(i, z) {
        if i.output.address.payment_credential == bond_pk {
          let bond_nft_tokens = value.tokens(i.output.value, bond_nft_pid)
          if (dict.size(bond_nft_tokens) == 1)? {
            expect Some(rdr) = dict.get(tx.redeemers, Spend(i.output_reference))
            expect action: BondIssueAction = rdr
            when action is {
              BondRedeem -> {
                expect obond_dt: BondDatum =
                  when i.output.datum is {
                    InlineDatum(d) -> d
                    _ ->
                      fail @"borrow_position/mint_bond.burn_bond_token: only supports InlineDatum for bond"
                  }
                if !list.has(z.1st, obond_dt.token_name) {
                  if and {
                    1 == 1,
                    ((
                      dict.get(bond_nft_tokens, obond_dt.token_name)
                        |> option.or_else(0)
                    ) == 1)?,
                  } {
                    when
                      dict.get(bond_token_burn_valid, obond_dt.token_name)
                    is {
                      Some(bond_token_burn_qty) ->
                        if (obond_dt.bond_amount > -bond_token_burn_qty)? {
                          (
                            [obond_dt.token_name, ..z.1st],
                            z.2nd + 1,
                            z.3rd,
                            z.4th,
                          )
                        } else if (obond_dt.bond_amount == -bond_token_burn_qty)? {
                          (
                            [obond_dt.token_name, ..z.1st],
                            z.2nd + 1,
                            [obond_dt.token_name, ..z.3rd],
                            z.4th + 1,
                          )
                        } else {
                          fail
                        }
                      _ -> z
                    }
                  } else {
                    fail @"bond utxo must only one bond_nft"
                  }
                } else {
                  fail @"bond utxo must be unique"
                }
              }
              _ -> z
            }
          } else {
            fail @"bond utxo must only one bond_nft name"
          }
        } else {
          z
        }
      },
    )
  if and {
    // burned bond_token(s) must associate with a spending bond along with bond_amount changes
    (bond_token_burn_valid_name_count == bond_token_burn_valid_name_inputs_count)?,
    (list.difference(
      dict.keys(bond_token_burn_valid),
      bond_token_burn_valid_name_inputs,
    ) == [])?,
  } {
    if bond_token_burn_all_valid_inputs_count > 0 {
      // if all of bond tokens in circulation are burned in this transaction, bond_nft must be burned 
      let bond_nft_burn_all_valid_count =
        dict.foldr(
          tx_mint_value |> value.tokens(bond_nft_pid),
          0,
          fn(n, q, z) {
            if and {
              list.has(bond_token_burn_all_valid_inputs, n),
              q == -1,
            } {
              z + 1
            } else {
              z
            }
          },
        )

      (bond_nft_burn_all_valid_count == bond_token_burn_all_valid_inputs_count)?
    } else {
      True
    }
  } else {
    fail
  }
}

// Minting bond_token(s) is requried when minting a bond nft. The correctness of minting 
// bond_nft is guaranteed by the corresponding redeemer of bond_token. So we just need
// to require the redeemer
pub fn create_bond_nft_with_bond_token_redeemer(
  tx: Transaction,
  bond_token_pid: PolicyId,
) -> Bool {
  expect Some(redeemer) = dict.get(tx.redeemers, Mint(bond_token_pid))
  expect bond_token_create: BondIssueAction = redeemer
  (bond_token_create == BondCreate)?
}

pub fn create(
  cfg: BondIssueConfig,
  tx: Transaction,
  bond_nft_pid: PolicyId,
  bond_token_pid: PolicyId,
) -> Bool {
  let (
    (bond_token_mint_valid, bond_token_mint_valid_name_count),
    (bond_nft_mint_valid_name, bond_nft_mint_valid_name_count),
  ) =
    dict.foldr(
      value.from_minted_value(tx.mint) |> value.to_dict(),
      ((dict.new(), 0), ([], 0)),
      fn(pid, assets, a) {
        if pid == bond_token_pid {
          (get_bond_token_mint(assets, a.1st), a.2nd)
        } else if pid == bond_nft_pid {
          (a.1st, get_bond_nft_mint(assets, a.2nd))
        } else {
          a
        }
      },
    )

  if and {
    (bond_token_mint_valid_name_count == bond_nft_mint_valid_name_count)?,
    (list.difference(dict.keys(bond_token_mint_valid), bond_nft_mint_valid_name) == [])?,
  } {
    let bond_name_avaiable =
      list.foldr(
        tx.inputs,
        [],
        fn(i, z) {
          let bond_name = hash_out_ref(i.output_reference)
          if !list.has(z, bond_name) {
            [bond_name, ..z]
          } else {
            fail @"bond_name must be unique"
          }
        },
      )
    and {
      (list.difference(bond_nft_mint_valid_name, bond_name_avaiable) == [])?,
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
                      fail @"borrow_position/mint_bond.create: only supports InlineDatum for bond"
                  }
                if !list.has(z.1st, obond_dt.token_name) {
                  expect Some(bond_token_mint_qty) =
                    dict.get(bond_token_mint_valid, obond_dt.token_name)
                  if and {
                    (o.address.stake_credential != None)?,
                    //
                    (obond_dt.bond_symbol == bond_token_pid)?,
                    list.has(bond_nft_mint_valid_name, obond_dt.token_name)?,
                    ((
                      dict.get(bond_nft_tokens, obond_dt.token_name)
                        |> option.or_else(0)
                    ) == 1)?,
                    //
                    (obond_dt.duration >= cfg.platform.min_duration)?,
                    (obond_dt.buffer >= cfg.platform.min_buffer)?,
                    (obond_dt.fee >= cfg.platform.fee)?,
                    (obond_dt.bond_amount > 0)?,
                    (obond_dt.bond_amount == bond_token_mint_qty)?,
                    (obond_dt.start == epoch_curr - cfg.epoch.epoch_boundary_as_epoch)?,
                  } {
                    let obond_principal =
                      obond_dt.bond_amount * cfg.platform.bond_face_value
                    let required_premium =
                      value.lovelace_of(pvalue.to_value(obond_dt.epo_rewards)) * math.min(
                        obond_dt.buffer + cfg.platform.prepaid_plus,
                        obond_dt.duration,
                      )
                    if
                    bond_asset_valid(
                      bond_nft_pid,
                      obond_dt,
                      o,
                      obond_principal + required_premium,
                    ){
                    
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
        (bond_name_outputs_valid_count == bond_nft_mint_valid_name_count)?
      },
    }
  } else {
    False
  }
}

fn get_bond_token_mint(
  assets: Dict<AssetName, Int>,
  zero: (Dict<AssetName, Int>, Int),
) -> (Dict<AssetName, Int>, Int) {
  dict.foldr(
    assets,
    zero,
    fn(n, q, z) {
      if (q > 0)? {
        (dict.insert(z.1st, n, q, bytearray.compare), z.2nd + 1)
      } else {
        fail @"must mint bond token only"
      }
    },
  )
}

fn get_bond_nft_mint(
  assets: Dict<AssetName, Int>,
  zero: (List<AssetName>, Int),
) -> (List<AssetName>, Int) {
  dict.foldr(
    assets,
    zero,
    fn(n, q, z) {
      if (q == 1)? {
        ([n, ..z.1st], z.2nd + 1)
      } else {
        fail @"must mint bond nft only one"
      }
    },
  )
}
