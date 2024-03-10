use aiken/dict
use aiken/list
use aiken/transaction.{InlineDatum, Output, Transaction}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondIssueConfig, RequestDatum} as bond_issue_types
use common/hash_out_refs.{hash_out_ref}
use issue_bond/utils.{check_output_request_base, get_burn_nft_names}

pub fn burning_force_redeem(tx: Transaction, borrower_pid: PolicyId) -> Bool {
  let burn_names = get_burn_nft_names(tx, borrower_pid)
  (list.length(burn_names) > 0)?
}

pub fn minting(
  cfg: BondIssueConfig,
  tx: Transaction,
  req_nft_pid: PolicyId,
  borrower_pid: PolicyId,
) -> Bool {
  let valid_request_token_names =
    list.map(tx.inputs, fn(inp) { hash_out_ref(inp.output_reference) })
  let mint_value = value.from_minted_value(tx.mint)

  let mint_borrower_nfts = value.tokens(mint_value, borrower_pid)
  let mint_borrower_nfts_valid =
    dict.filter(
      mint_borrower_nfts,
      fn(n, q) { list.has(valid_request_token_names, n) && q == 1 },
    )
  let mint_req_nfts = value.tokens(mint_value, req_nft_pid)
  let mint_req_nfts_valid =
    dict.filter(
      mint_req_nfts,
      fn(n, q) { list.has(valid_request_token_names, n) && q == 1 },
    )
  let req_pk = ScriptCredential(req_nft_pid)
  let dist_req_nfts =
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
            (value.quantity_of(o.value, req_nft_pid, oreq_dt.borrower) == 1)?,
            dict.has_key(mint_req_nfts_valid, oreq_dt.borrower)?,
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
  and {
    (dict.size(mint_borrower_nfts) == dict.size(mint_borrower_nfts_valid))?,
    (dict.size(mint_req_nfts) == dict.size(mint_req_nfts_valid))?,
    (dict.size(mint_req_nfts) == list.length(dist_req_nfts))?,
    (dict.size(mint_borrower_nfts) == list.length(dist_req_nfts))?,
  }
}
