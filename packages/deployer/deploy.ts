import {
  BASIS_POINTS,
  Deployer,
  EPOCH_CONFIG,
  KoiosProvider,
  SLOT_CONFIG,
  hashUtxoByOutRef,
  readBlueprint,
  safeStringify,
  toInterface,
  type StakeCredential,
} from '@danogojs/sdk';
import {
  Data,
  Lucid,
  applyDoubleCborEncoding,
  paymentCredentialOf,
  toUnit,
  type UTxO,
} from 'lucid-cardano';
import path from 'path';
import {
  ProtocolParams,
  defaultStakeCred,
  platformConfig,
  redeemOverEpochs,
  type BondIssueConfig,
} from './config';
import invariant from 'tiny-invariant';

const { NETWORK, KOIOS_PROJECT_ID, SEED } = process.env;

class BondIssueDeployer extends Deployer {
  private lucid?: Lucid;
  // flags
  RETRY_PREVIOUS_DEPLOY = true;

  constructor() {
    super();
    this.settings = {
      minFund: 30_000_000n,
      minFundUtxoCount: 8,
    };
  }

  async getLucidInstance(): Promise<Lucid> {
    if (!this.lucid) {
      const provider = new KoiosProvider(NETWORK, KOIOS_PROJECT_ID);
      const lucid = await Lucid.new(provider, NETWORK);
      lucid.selectWalletFromSeed(SEED);
      this.lucid = lucid;
    }
    return this.lucid;
  }

  async deploy() {
    await this.mintProtocolNft()
      .then((args) => this.deployValidators(args))
      .then((args) => this.deployProtocolParams(args));
  }

  async mintProtocolNft() {
    this.log('Minting protocol nft');
    const validators = this.readValidators();
    const { definitions, buildProtocolPolicy } = validators;
    const lucid = await this.getLucidInstance();
    const ownAddr = await this.getOwnAddress();
    const ownerPk = paymentCredentialOf(ownAddr).hash;

    const protocolPolicy = buildProtocolPolicy(ownerPk);
    const protocolNftPid = lucid.utils.validatorToScriptHash(protocolPolicy);

    if (this.RETRY_PREVIOUS_DEPLOY) {
      // Reuse minted nft under the protocol policy if already minted
      const ownUtxos = await lucid.wallet.getUtxos();
      const [mintedProtocolUtxo, mintedNft] = ownUtxos.reduce(
        (result, utxo) => {
          if (utxo.scriptRef) return result;

          const nftName = Object.keys(utxo.assets).find(
            (unit) =>
              unit.startsWith(protocolNftPid) && utxo.assets[unit] === 1n
          );

          if (nftName) {
            return [utxo, nftName];
          }

          return result;
        },
        [undefined, undefined] as [UTxO | undefined, string | undefined]
      );

      if (mintedProtocolUtxo && mintedNft) {
        this.log(`Reuse NFT: ${mintedNft}`);
        return {
          ...validators,
          protocolNftPid,
          protocolNftName: mintedNft.split(protocolNftPid)[1],
          protocolNft: mintedNft,
          protocolPolicy,
          ownerPk,
          protocolNftUtxo: mintedProtocolUtxo,
        };
      }
    }

    // No minted nft, minting new one
    const seedUtxo = this.getFundUtxo();
    const protocolNftName = hashUtxoByOutRef(seedUtxo);
    const protocolNft = toUnit(protocolNftPid, protocolNftName);

    await this.makeTx(
      (tx) =>
        tx
          .addSignerKey(ownerPk)
          .collectFrom([seedUtxo])
          .attachMintingPolicy({
            type: 'PlutusV2',
            script: applyDoubleCborEncoding(protocolPolicy.script),
          })
          .mintAssets(
            {
              [protocolNft]: 1n,
            },
            toInterface(
              'MintProtocol',
              definitions['protocol_params/types/ProtocolParamsAction']
            )
          ),
      {
        // As we need the protocol nft utxo to pay to the spending address later,
        // we need to wait for the tx propagated successfully. Without this, we
        // would fail at the deploy protocol params step due to exhausted inputs
        waitForTxPropagated: true,
      }
    );

    const protocolNftUtxo = (await lucid.wallet.getUtxos()).find(
      (utxo) => utxo.assets[protocolNft] === 1n
    );

    if (!protocolNftUtxo) {
      throw Error('Ops. protocolNftUtxo not found');
    }

    return {
      ...validators,
      protocolNftPid,
      protocolNftName,
      protocolNft,
      protocolPolicy,
      ownerPk,
      protocolNftUtxo,
    };
  }

  async deployValidators({
    protocolNftPid,
    protocolNftName,
    protocolNft,
    buildBorrowRequestNftPolicy,
    buildBorrowerNftPolicy,
    buildBondNftPolicy,
    buildBondNftSpending,
    buildBondTokenPolicy,
    buildBorrowRequestSpending,
    buildProtocolSpending,
    ownerPk,
    protocolNftUtxo,
  }: Awaited<ReturnType<typeof this.mintProtocolNft>>) {
    const config: BondIssueConfig = {
      slot: SLOT_CONFIG[NETWORK],
      epoch: EPOCH_CONFIG[NETWORK],
      basis: BASIS_POINTS,
      platform: platformConfig[NETWORK],
    };
    const parameterizedParams = {
      config,
      defaultStakeCred: defaultStakeCred[NETWORK],
      redeemOverEpochs: redeemOverEpochs[NETWORK],
      protocolNftPid,
      protocolNftName,
    };

    this.log(parameterizedParams);

    const protocolSpending = buildProtocolSpending(ownerPk);
    const borrowerNftPolicy = buildBorrowerNftPolicy();
    const borrowRequestPolicy = buildBorrowRequestNftPolicy(
      protocolNftPid,
      protocolNftName,
      config
    );
    const borrowRequestSpending = buildBorrowRequestSpending(
      protocolNftPid,
      protocolNftName,
      config
    );
    const bondNftPolicy = buildBondNftPolicy(
      protocolNftPid,
      protocolNftName,
      config,
      parameterizedParams.redeemOverEpochs
    );
    const bondNftSpending = buildBondNftSpending(
      protocolNftPid,
      protocolNftName,
      config,
      parameterizedParams.defaultStakeCred
    );
    const bondTokenPolicy = buildBondTokenPolicy(
      protocolNftPid,
      protocolNftName,
      config
    );

    const scripts = [
      protocolSpending,
      borrowerNftPolicy,
      borrowRequestPolicy,
      borrowRequestSpending,
      bondNftPolicy,
      bondNftSpending,
      bondTokenPolicy,
    ];

    for await (const script of scripts) {
      await this.deployScript(script);
    }

    return {
      protocolSpending,
      borrowerNftPolicy,
      borrowRequestPolicy,
      borrowRequestSpending,
      bondNftPolicy,
      bondNftSpending,
      bondTokenPolicy,
      protocolNft,
      protocolNftUtxo,
      parameterizedParams,
    };
  }

  async deployProtocolParams({
    protocolSpending,
    bondNftPolicy,
    bondTokenPolicy,
    borrowRequestSpending,
    borrowerNftPolicy,
    protocolNft,
    protocolNftUtxo,
    bondNftSpending,
    borrowRequestPolicy,
    parameterizedParams,
  }: Awaited<ReturnType<typeof this.deployValidators>>) {
    this.log('Start deploy protocol params');
    const lucid = await this.getLucidInstance();
    const protocolParams: typeof ProtocolParams = {
      bond_nft_pid: lucid.utils.validatorToScriptHash(bondNftPolicy),
      bond_skh: lucid.utils.validatorToScriptHash(bondNftSpending),
      bond_token_pid: lucid.utils.validatorToScriptHash(bondTokenPolicy),
      borrow_request_pid:
        lucid.utils.validatorToScriptHash(borrowRequestPolicy),
      borrow_request_skh: lucid.utils.validatorToScriptHash(
        borrowRequestSpending
      ),
      borrower_pid: lucid.utils.validatorToScriptHash(borrowerNftPolicy),
    };
    const summary = this.getDeployedSummary();
    const fundUtxo = this.getFundUtxo();
    const protocolAddress = lucid.utils.validatorToAddress(protocolSpending);

    const txHash = await this.makeTx((tx) =>
      tx
        .collectFrom([fundUtxo, protocolNftUtxo])
        .payToContract(
          protocolAddress,
          { inline: Data.to(protocolParams, ProtocolParams) },
          {
            [protocolNft]: 1n,
          }
        )
        .attachMetadata(0, JSON.parse(safeStringify(parameterizedParams)))
        .attachMetadata(1, summary)
    );

    this.log(`Protocol Params at: ${txHash}#0`);
    this.log(`Done!`);
  }

  readValidators() {
    const blueprintPath = path.resolve(__dirname, '../../plutus.json');
    const {
      blueprint: { definitions },
      getValidator,
    } = readBlueprint(blueprintPath);

    return {
      definitions,
      buildProtocolPolicy: (owner: string) => {
        const validator = getValidator('protocol.mint_protocol', [owner]);
        return validator;
      },
      buildProtocolSpending: (owner: string) => {
        const validator = getValidator('protocol.spend_protocol', [owner]);
        return validator;
      },
      buildBorrowerNftPolicy: () => getValidator('request.mint_borrower_nft'),
      buildBorrowRequestNftPolicy: (
        protocolNftPid: string,
        protocolNftName: string,
        config: BondIssueConfig
      ) => {
        const validator = getValidator('request.mint_request_nft', [
          protocolNftPid,
          protocolNftName,
          config,
        ]);
        return validator;
      },
      buildBorrowRequestSpending: (
        protocolNftPid: string,
        protocolNftName: string,
        config: BondIssueConfig
      ) => {
        const validator = getValidator('request.spend_request', [
          protocolNftPid,
          protocolNftName,
          config,
        ]);
        return validator;
      },
      buildBondTokenPolicy: (
        protocolNftPid: string,
        protocolNftName: string,
        config: BondIssueConfig
      ) => {
        const validator = getValidator('bond.mint_bond_token', [
          protocolNftPid,
          protocolNftName,
          config,
        ]);
        return validator;
      },
      buildBondNftPolicy: (
        protocolNftPid: string,
        protocolNftName: string,
        config: BondIssueConfig,
        redeemOverEpochs: bigint
      ) => {
        const validator = getValidator('bond.mint_bond_nft', [
          protocolNftPid,
          protocolNftName,
          config,
          redeemOverEpochs,
        ]);
        return validator;
      },
      buildBondNftSpending: (
        protocolNftPid: string,
        protocolNftName: string,
        config: BondIssueConfig,
        stakeCred: StakeCredential
      ) => {
        const validator = getValidator('bond.spend_bond', [
          protocolNftPid,
          protocolNftName,
          config,
          stakeCred,
        ]);
        return validator;
      },
    };
  }
}

await (async function main() {
  const deployer = new BondIssueDeployer();
  await deployer.run();
})();
