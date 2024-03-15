use aiken/list
use aiken/transaction.{InlineDatum, Transaction}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{AssetName, PolicyId}
use protocol_params/types.{ProtocolParams}

fn fail_if_none(self: Option<a>, msg: String) {
  when self is {
    None -> fail msg
    Some(v) -> v
  }
}

pub fn get_protocol_params(
  nft_pid: PolicyId,
  nft_name: AssetName,
  tx: Transaction,
) {
  let input =
    list.find(tx.reference_inputs, fn(inp) { and {
          value.quantity_of(inp.output.value, nft_pid, nft_name) == 1,
          inp.output.address.payment_credential == ScriptCredential(nft_pid),
        } })
      |> fail_if_none(@"protocol params not found")
  expect InlineDatum(dtm) = input.output.datum
  expect params: ProtocolParams = dtm
  params
}
