use aiken/list
use aiken/transaction.{Input,
  OutputReference, ScriptContext, Spend, Transaction}
use aiken/transaction/credential.{VerificationKeyCredential}
use aiken/transaction/value.{PolicyId}
use bond_issue/types.{BondIssueConfig, RequestDatum}
use common/util.{find_while}

pub fn get_input_out_ref(
  inputs: List<Input>,
  out_ref: OutputReference,
) -> OutputReference {
  expect Some(sreq) = list.find(inputs, fn(i) { i.output_reference == out_ref })
  sreq.output_reference
}

pub fn get_out_ref(
  ctx: ScriptContext,
  out_ref: OutputReference,
) -> (Input, Option<Input>) {
  expect Spend(sout_ref) = ctx.purpose
  expect (Some(spending_input), out_ref_input) =
    find_while(
      ctx.transaction.inputs,
      (None, None),
      fn(i, z) {
        let r =
          if i.output_reference == sout_ref {
            (Some(i), z.2nd)
          } else if i.output_reference == out_ref {
            (z.1st, Some(i))
          } else {
            z
          }
        (r.1st != None && r.2nd != None, r)
      },
    )
  (spending_input, out_ref_input)
}

pub fn calc_requried_premium(
  cfg: BondIssueConfig,
  req_dtm: RequestDatum,
  issue_qty: Int,
) {
  let principal = issue_qty * cfg.platform.bond_face_value
  let epo_rewards =
    principal * req_dtm.apr / cfg.basis.base / cfg.epoch.year_to_epoch
  epo_rewards * req_dtm.prepaid
}

pub fn is_borrower_authenticated(
  tx: Transaction,
  borrower_pid: PolicyId,
  borrower: ByteArray,
) {
  let borrower_nft_predicate =
    fn(in: Input) {
      value.quantity_of(in.output.value, borrower_pid, borrower) == 1
    }
  or {
    // authenticated by spending borrower nft
    list.any(tx.inputs, borrower_nft_predicate),
    // authenticated by borrower signartory
    when list.find(tx.reference_inputs, borrower_nft_predicate) is {
      None -> False
      Some(in) -> {
        expect VerificationKeyCredential(borrower_pk) =
          in.output.address.payment_credential
        list.has(tx.extra_signatories, borrower_pk)
      }
    },
  }
}
