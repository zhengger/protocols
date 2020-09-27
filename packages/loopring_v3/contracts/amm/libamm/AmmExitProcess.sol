// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../../aux/transactions/TransactionReader.sol";
import "../../core/impl/libtransactions/TransferTransaction.sol";
import "../../lib/EIP712.sol";
import "../../lib/ERC20SafeTransfer.sol";
import "../../lib/MathUint.sol";
import "../../lib/MathUint96.sol";
import "../../thirdparty/SafeCast.sol";
import "./AmmUtil.sol";
import "./AmmData.sol";
import "./AmmExitRequest.sol";
import "./AmmPoolToken.sol";
import "./AmmStatus.sol";


/// @title AmmExitProcess
library AmmExitProcess
{
    using AmmPoolToken      for AmmData.State;
    using AmmStatus         for AmmData.State;
    using AmmUtil           for uint96;
    using ERC20SafeTransfer for address;
    using MathUint          for uint;
    using MathUint96        for uint96;
    using SafeCast          for uint;
    using TransactionReader for ExchangeData.Block;

    function proxcessExchangeWithdrawal(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.Token    memory  token,
        uint                     amount
        )
        internal
    {
        // Check that the withdrawal in the block matches the expected withdrawal
        WithdrawTransaction.Withdrawal memory withdrawal = ctx._block.readWithdrawal(ctx.txIdx++);
        ctx.numTransactionsConsumed++;

        // These fields are not read by readWithdrawal: storageID
        withdrawal.minGas = 0;
        withdrawal.to = address(this);
        withdrawal.extraData = new bytes(0);

        require(
            withdrawal.withdrawalType == 1 &&
            withdrawal.owner == address(this) &&
            withdrawal.accountID == S.accountID &&
            withdrawal.tokenID == token.tokenID &&
            withdrawal.amount == amount && //No rounding errors because we put in the complete uint96 in the DA.
            withdrawal.feeTokenID == 0 &&
            withdrawal.fee == 0 &&
            withdrawal.onchainDataHash == WithdrawTransaction.hashOnchainData(
                withdrawal.minGas,
                withdrawal.to,
                withdrawal.extraData
            ),
            "INVALID_TX_DATA"
        );

        // Now approve this withdrawal
        withdrawal.validUntil = 0xffffffff;
        bytes32 txHash = WithdrawTransaction.hashTx(ctx.exchangeDomainSeparator, withdrawal);
        ctx.exchange.approveTransaction(address(this), txHash);

        // Total balance in this contract increases by the amount withdrawn
        S.totalUserBalance[token.addr] = S.totalUserBalance[token.addr].add(amount);
    }

    function processExit(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.PoolExit memory  exit,
        bytes            memory  signature
        )
        internal
    {
        S.validatePoolTransaction(
            exit.owner,
            AmmExitRequest.hashPoolExit(ctx.domainSeparator, exit),
            signature
        );

        if (signature.length == 0) {
            // This is an onchain exit, we're processing it now so stop tracking it.
            S.isExiting[exit.owner] = false;
        }

        (bool slippageRequirementMet, uint96[] memory amounts) = _validateExitAmounts(S, ctx, exit);

        if (!slippageRequirementMet) return;

        for (uint i = 0; i < ctx.size; i++) {
            uint96 amount = amounts[i];
            if (exit.toLayer2) {
                TransferTransaction.Transfer memory transfer = ctx._block.readTransfer(ctx.txIdx++);
                ctx.numTransactionsConsumed++;

                require(
                    transfer.fromAccountID == S.accountID &&
                    transfer.from == address(this) &&
                    transfer.to == exit.owner &&
                    transfer.tokenID == ctx.tokens[i].tokenID &&
                    transfer.amount.isAlmostEqual(amount) &&
                    transfer.feeTokenID == ctx.tokens[i].tokenID &&
                    transfer.fee == 0,
                    "INVALID_TX_DATA"
                );

                // Replay protection when using a signature (otherwise the approved hash is cleared onchain)
                if (signature.length > 0) {
                    require(transfer.storageID == exit.storageIDs[i], "INVALID_TX_DATA");
                }

                // Now approve this transfer
                transfer.validUntil = 0xffffffff;
                bytes32 txHash = TransferTransaction.hashTx(ctx.exchangeDomainSeparator, transfer);
                ctx.exchange.approveTransaction(address(this), txHash);

                amount = transfer.amount;
                ctx.ammActualL2Balances[i] = ctx.ammActualL2Balances[i].sub(amount);
            } else {
                address token = ctx.tokens[i].addr;
                // Make the amount available for withdrawing
                S.userBalance[token][exit.owner] = S.userBalance[token][exit.owner].add(amount);
            }

            ctx.ammExpectedL2Balances[i] = ctx.ammExpectedL2Balances[i].sub(amount);
        }

        S.removeUserBalance(address(this), exit.owner, exit.poolAmountIn);
        S.burn(address(this), exit.poolAmountIn);
    }

    function _validateExitAmounts(
        AmmData.State    storage S,
        AmmData.Context  memory  ctx,
        AmmData.PoolExit memory  exit
        )
        private
        view
        returns(
            bool /* slippageRequirementMet */,
            uint96[] memory amounts
        )
    {
        amounts = new uint96[](ctx.size);

        // Check if we can still use this exit
        if (block.timestamp > exit.validUntil) {
            return (false, amounts);
        }

        // Check if the user has enough pool tokens locked
        if (S.lockedBalance(address(this), exit.owner) < exit.poolAmountIn) {
            return (false, amounts);
        }

        // Calculate how much will be withdrawn
        uint ratio = exit.poolAmountIn.mul(ctx.poolTokenBase) / S.totalSupply;

        for (uint i = 0; i < ctx.size; i++) {
            amounts[i] = (ratio.mul(ctx.ammExpectedL2Balances[i]) / ctx.poolTokenBase).toUint96();
            if (amounts[i] < exit.minAmountsOut[i]) {
                return (false, amounts);
            }
        }

        return (true, amounts);
    }
}