import {
  addressFromBech32,
  inlineStakeCredentialFromHex,
  type StakeCredential,
} from '@danogojs/sdk';
import { Data, type Network } from 'lucid-cardano';

// This type should be generated from blueprint to verify the correctness of the config
// Run this command in the containing folder of plutus.json to generate interfaces:
// $ deno run -A https://deno.land/x/lucid@0.10.7/blueprint.ts
export type BondIssueConfig = {
  slot: { zeroTime: bigint; zeroSlot: bigint; slotLength: bigint };
  epoch: {
    yearToEpoch: bigint;
    epochBoundary: bigint;
    epochBoundaryAsEpoch: bigint;
    epochLength: bigint;
    epochLengthBase: bigint;
  };
  basis: { base: bigint; min: bigint; max: bigint };
  platform: {
    bondFaceValue: bigint;
    fee: bigint;
    feeAddr: {
      paymentCredential:
        | { VerificationKeyCredential: [string] }
        | {
            ScriptCredential: [string];
          };
      stakeCredential:
        | {
            Inline: [
              | { VerificationKeyCredential: [string] }
              | {
                  ScriptCredential: [string];
                }
            ];
          }
        | {
            Pointer: {
              slotNumber: bigint;
              transactionIndex: bigint;
              certificateIndex: bigint;
            };
          }
        | null;
    };
    txTtl: bigint;
    minBuffer: bigint;
    prepaidPlus: bigint;
    minRequested: bigint;
    minApr: bigint;
    minDuration: bigint;
    minAda: bigint;
  };
};

const defaultPlatformConfig: BondIssueConfig['platform'] = {
  // 1 bond = 100 ADA = 100_000_000 lovelace. default: 100 ADA = 100_000_000 lovelace
  bondFaceValue: 100_000_000n,
  // value in range 0001 -> 9999 default: 500 (5%) per apr
  fee: 500n,
  // fee receive address
  feeAddr: addressFromBech32(
    'addr_test1qze3a4r9l7dw0vpfs8h946g4ja7mc4vf0k7vkl4rn67n5z6n20929h28d2tdu49lckh6jwpqmy5utgv39492sww3l9vq7wvaet'
  ),
  // Khoảng thời gian giao dịch hợp lệ, giá trị tính theo slot
  txTtl: 6n * 60n,
  // default: 6 epoch
  minBuffer: 1n,
  // datum.prepaid = Min(<min_buffer>+prepaid_plus, <duration>)
  prepaidPlus: 1n,
  // default: 100 Bond = 10_000 ADA
  minRequested: 1n,
  // default: 200 (2.00%)
  minApr: 200n,
  // default: 6 epoch
  minDuration: 1n,
  // default: 2
  minAda: 2_000_000n,
};

export const platformConfig: Record<Network, BondIssueConfig['platform']> = {
  Preview: defaultPlatformConfig,
  Preprod: defaultPlatformConfig,
  Mainnet: {
    ...defaultPlatformConfig,
    feeAddr: addressFromBech32(
      'addr1qxcfvgwm9q3sq56vepctw56pe6ps8npffldj5sa5j25vywrw2aappdz98nah303sy0dc3p83x4hewv5z5c44q2sfqgqq674csz'
    ),
  },
  Custom: defaultPlatformConfig,
};

const ProtocolParamsSchema = Data.Object({
  bond_nft_pid: Data.Bytes(),
  bond_skh: Data.Bytes(),
  bond_token_pid: Data.Bytes(),
  borrower_pid: Data.Bytes(),
  borrow_request_pid: Data.Bytes(),
  borrow_request_skh: Data.Bytes(),
});

export const ProtocolParams = ProtocolParamsSchema as unknown as Data.Static<
  typeof ProtocolParamsSchema
>;

export const defaultStakeCred: Record<Network, StakeCredential> = {
  Preview: inlineStakeCredentialFromHex(
    '5353caa2dd476a96de54bfc5afa93820d929c5a1912d4aa839d1f958'
  ),
  Preprod: inlineStakeCredentialFromHex(
    '5353caa2dd476a96de54bfc5afa93820d929c5a1912d4aa839d1f958'
  ),
  Mainnet: inlineStakeCredentialFromHex(
    '6e577a10b4453cfb78be3023db8884f1356f973282a62b502a090200'
  ),
  Custom: inlineStakeCredentialFromHex(
    '5353caa2dd476a96de54bfc5afa93820d929c5a1912d4aa839d1f958'
  ),
};

export const redeemOverEpochs: Record<Network, bigint> = {
  Preview: 1n,
  Custom: 1n,
  Preprod: 72n,
  Mainnet: 72n,
};
