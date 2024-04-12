use aiken/list
use aiken/transaction.{Output, ScriptContext, Transaction}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondIssueConfig, RequestDatum} as bond_issue_types
use borrow_request/utils.{is_borrower_authenticated} as request_utils
use common/data
use common/types.{ScriptKeyHash} as common_types
use issue_bond/utils.{check_output_request_base}

pub fn spending(
  cfg: BondIssueConfig,
  ctx: ScriptContext,
  sreq_dt: RequestDatum,
  req_nft_pid: PolicyId,
  req_skh: ScriptKeyHash,
) -> Bool {
  let tx = ctx.transaction
  let is_burned_borrow_request_nft =
    value.quantity_of(
      value.from_minted_value(tx.mint),
      req_nft_pid,
      sreq_dt.borrower,
    ) == -1
  and {
    is_borrower_authenticated(tx, sreq_dt.symbol, sreq_dt.borrower)?,
    or {
      has_continuous_request(cfg, tx, sreq_dt, req_nft_pid, req_skh)?,
      is_burned_borrow_request_nft?,
    },
  }
}

fn has_continuous_request(
  cfg: BondIssueConfig,
  tx: Transaction,
  sreq_dt: RequestDatum,
  req_nft_pid: PolicyId,
  req_skh: ScriptKeyHash,
) -> Bool {
  when list.filter(tx.outputs, fn(out) { and {
          ScriptCredential(req_skh) == out.address.payment_credential,
          value.quantity_of(out.value, req_nft_pid, sreq_dt.borrower) == 1,
        } }) is {
    [] -> False
    [oreq] -> {
      expect oreq_dt: RequestDatum = data.output_datum(oreq)
      and {
        (oreq_dt.symbol == sreq_dt.symbol)?,
        (oreq_dt.borrower == sreq_dt.borrower)?,
        (oreq_dt.issued == sreq_dt.issued)?,
        (oreq_dt.issued >= 0)?,
        (oreq.address.stake_credential != None)?,
        check_output_request_base(cfg, oreq, oreq_dt)?,
        (oreq_dt.requested >= oreq_dt.issued)?,
      }
    }
    _ -> fail @"Unreachable: borrow request nft duplication"
  }
}
