use aiken/dict
use aiken/list
use aiken/option
use aiken/transaction.{InlineDatum, Transaction}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondIssueConfig, RequestDatum} as bond_issue_types
use common/hash_out_refs.{hash_out_ref}
use issue_bond/utils.{
  check_output_request_base, get_burn_nft_names, get_output_by_nft_names,
}

pub fn burning_valid(tx: Transaction, req_nft_pid: PolicyId) -> Bool {
  let burn_names = get_burn_nft_names(tx, req_nft_pid)
  let oreq = get_output_by_nft_names(tx, burn_names, req_nft_pid)
  and {
    (list.length(burn_names) > 0)?,
    (list.length(oreq) == 0)?,
  }
}

pub fn minting(
  cfg: BondIssueConfig,
  tx: Transaction,
  req_nft_pid: PolicyId,
  req_nft_skh: ByteArray,
  borrower_pid: PolicyId,
) -> Bool {
  let req_nft_name_valids =
    list.map(tx.inputs, fn(i) { hash_out_ref(i.output_reference) })
  let req_nft_mint = value.tokens(value.from_minted_value(tx.mint), req_nft_pid)
  let (req_nft_name_mint_valid, req_nft_name_mint_valid_count) =
    dict.foldr(
      req_nft_mint,
      ([], 0),
      fn(n, q, z) {
        if list.has(req_nft_name_valids, n)? && (q == 1)? {
          ([n, ..z.1st], z.2nd + 1)
        } else {
          z
        }
      },
    )
  if (dict.size(req_nft_mint) == req_nft_name_mint_valid_count)? {
    let req_pk = ScriptCredential(req_nft_skh)
    let req_nft_outputs =
      list.filter(
        tx.outputs,
        fn(o) {
          let req_tokens = value.tokens(o.value, req_nft_pid)
          if and {
            o.address.payment_credential == req_pk,
            dict.size(req_tokens) == 1,
          } {
            expect oreq_dt: RequestDatum =
              when o.datum is {
                InlineDatum(d) -> d
                _ -> fail @"only supports InlineDatum for borrow request"
              }
            if and {
              (( dict.get(req_tokens, oreq_dt.borrower) |> option.or_else(0) ) == 1)?,
              list.has(req_nft_name_mint_valid, oreq_dt.borrower)?,
              (oreq_dt.issued == 0)?,
              (o.address.stake_credential != None)?,
              check_output_request_base(cfg, o, oreq_dt)?,
              (oreq_dt.requested >= oreq_dt.issued)?,
              (oreq_dt.symbol == borrower_pid)?,
            } {
              True
            } else {
              fail
            }
          } else {
            False
          }
        },
      )
    (req_nft_name_mint_valid_count == list.length(req_nft_outputs))?
  } else {
    fail
  }
}
