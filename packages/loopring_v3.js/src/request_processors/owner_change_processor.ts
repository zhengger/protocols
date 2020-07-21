import BN from "bn.js";
import { Bitstream } from "../bitstream";
import { Constants } from "../constants";
import { EdDSA } from "../eddsa";
import { fromFloat } from "../float";
import { BlockContext, ExchangeState } from "../types";

interface OwnerChange {
  owner?: string;
  accountID?: number;
  nonce?: number;
  feeTokenID?: number;
  fee?: BN;
  newOwner?: string;
  walletHash?: string;
}

/**
 * Processes owner change requests.
 */
export class OwnerChangeProcessor {
  public static process(state: ExchangeState, block: BlockContext, txData: Bitstream) {
    const change = this.extractData(txData);

    const index = state.getAccount(1);

    const account = state.getAccount(change.accountID);
    account.owner = change.newOwner;
    account.nonce++;

    const balance = account.getBalance(change.feeTokenID, index);
    balance.balance.isub(change.fee);

    const operator = state.getAccount(block.operatorAccountID);
    const balanceO = operator.getBalance(change.feeTokenID, index);
    balanceO.balance.iadd(change.fee);

    return change;
  }

  public static extractData(data: Bitstream) {
    const change: OwnerChange = {};
    let offset = 1;

    change.owner = data.extractAddress(offset);
    offset += 20;
    change.accountID = data.extractUint24(offset);
    offset += 3;
    change.nonce = data.extractUint32(offset);
    offset += 4;
    change.feeTokenID = data.extractUint16(offset);
    offset += 2;
    change.fee = fromFloat(data.extractUint16(offset), Constants.Float16Encoding);
    offset += 2;
    change.newOwner = data.extractAddress(offset);
    offset += 20;
    change.walletHash = data.extractUint(offset).toString(10);
    offset += 32;

    return change;
  }
}