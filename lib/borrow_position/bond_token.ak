use aiken/dict
use aiken/list
use aiken/transaction.{InlineDatum, OutputReference, Transaction}
use aiken/transaction/credential.{Address, ScriptCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondDatum, BondIssueConfig, RequestDatum}
use common/hash_out_refs.{hash_out_ref_salt}
use common/types.{ScriptKeyHash} as common_types
use issue_bond/utils.{
  check_output_request_base, get_burn_token_names, get_input_by_nft_names,
}

pub fn burning_bond_redeem(
  tx: Transaction,
  bond_pid: PolicyId,
  nft_pid: PolicyId,
) -> Bool {
  let burn_names = get_burn_token_names(tx, bond_pid)
  let ibond = get_input_by_nft_names(tx, burn_names, nft_pid)
  and {
    (list.length(burn_names) > 0)?,
    (list.length(ibond) == list.length(burn_names))?,
  }
}

pub fn burning_force_redeem(tx: Transaction, bond_pid: PolicyId) -> Bool {
  let burn_names = get_burn_token_names(tx, bond_pid)
  (list.length(burn_names) > 0)?
}

pub fn minting_without_fee(
  cfg: BondIssueConfig,
  tx: Transaction,
  req_skh: ScriptKeyHash,
  bond_skh: ScriptKeyHash,
  nft_pid: PolicyId,
  bond_pid: PolicyId,
  out_ref: OutputReference,
) -> Bool {
  let mint_value = value.from_minted_value(tx.mint)
  let mint_bond_tokens = value.tokens(mint_value, bond_pid)
  let mint_nft_tokens = value.tokens(mint_value, nft_pid)
  if and {
    (dict.size(mint_bond_tokens) == dict.size(mint_nft_tokens))?,
    (list.difference(dict.keys(mint_bond_tokens), dict.keys(mint_nft_tokens)) == [])?,
  } {
    let req_pk = ScriptCredential(req_skh)
    when
      list.foldr(
        tx.inputs,
        (None, None),
        fn(i, z) {
          if and {
            i.output_reference == out_ref,
            i.output.address.payment_credential == req_pk,
          } {
            expect sreq_dt: RequestDatum =
              when i.output.datum is {
                InlineDatum(d) -> d
                _ -> fail @"only supports InlineDatum for request"
              }
            if and {
              // (value.quantity_of(i.output.value, req_pid, sreq_dt.borrower) == 1)?,
              (i.output.address.stake_credential != None)?,
              check_output_request_base(cfg, i.output, sreq_dt)?,
              (sreq_dt.requested >= sreq_dt.issued)?,
            } {
              if z.1st == None {
                (Some(sreq_dt), Some(i))
              } else {
                fail @"borrow request is unique"
              }
            } else {
              z
            }
          } else {
            z
          }
        },
      )
    is {
      (Some(sreq_dt), Some(i)) -> {
        let bond_name = hash_out_ref_salt(out_ref, sreq_dt.borrower)
        let mint_qty = value.quantity_of(mint_value, bond_pid, bond_name)
        let bond_addr =
          Address {
            payment_credential: ScriptCredential(bond_skh),
            stake_credential: i.output.address.stake_credential,
          }
        when
          list.filter(
            tx.outputs,
            fn(o) {
              if and {
                o.address == bond_addr,
                value.quantity_of(o.value, nft_pid, bond_name) == 1,
              } {
                expect obond_dt: BondDatum =
                  when o.datum is {
                    InlineDatum(d) -> d
                    _ ->
                      fail @"borrow_position/bond_nft.minting: only supports InlineDatum for bond"
                  }
                and {
                  (obond_dt.bond_symbol == bond_pid)?,
                  (obond_dt.token_name == bond_name)?,
                  (obond_dt.borrower == sreq_dt.borrower)?,
                  (obond_dt.bond_amount == mint_qty)?,
                }
              } else {
                False
              }
            },
          )
        is {
          [_o] -> True
          _ -> fail @"not found bond utxo output"
        }
      }
      _ -> fail @"not found borrow request input"
    }
  } else {
    False
  }
}
