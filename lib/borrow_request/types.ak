use aiken/transaction.{Output}

// (request output, bond_output, mint_qty)
pub type BondCreateOutput =
  (Option<Output>, Option<Output>, Int)
