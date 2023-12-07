// SPDX-License-Identifier: MIT

/*

__/\\\\____________/\\\\_____/\\\\\\\\\_____/\\\\\\\\\\\\_____/\\\\\\\\\\\\\\\__/\\\\\\\\\\\_
 _\/\\\\\\________/\\\\\\___/\\\\\\\\\\\\\__\/\\\////////\\\__\/\\\///////////__\/////\\\///__
  _\/\\\//\\\____/\\\//\\\__/\\\/////////\\\_\/\\\______\//\\\_\/\\\_________________\/\\\_____
   _\/\\\\///\\\/\\\/_\/\\\_\/\\\_______\/\\\_\/\\\_______\/\\\_\/\\\\\\\\\\\_________\/\\\_____
    _\/\\\__\///\\\/___\/\\\_\/\\\\\\\\\\\\\\\_\/\\\_______\/\\\_\/\\\///////__________\/\\\_____
     _\/\\\____\///_____\/\\\_\/\\\/////////\\\_\/\\\_______\/\\\_\/\\\_________________\/\\\_____
      _\/\\\_____________\/\\\_\/\\\_______\/\\\_\/\\\_______/\\\__\/\\\_________________\/\\\_____
       _\/\\\_____________\/\\\_\/\\\_______\/\\\_\/\\\\\\\\\\\\/___\/\\\______________/\\\\\\\\\\\_
        _\///______________\///__\///________\///__\////////////_____\///______________\///////////__

*/

pragma solidity ^0.8.10;

import {ISwapRouter} from "../interfaces/IUniswap.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IMadSBT.sol";
import "../interfaces/ISuperToken.sol";

library RevShare {
    error InsufficientAmountInForQuote();

    /**
     * @dev Distribute rewards to a collection
     * @param madSBT The MadSBT contract
     * @param revShareAmount The amount of rewards to distribute
     * @param collectionId The collection to distribute rewards to
     * @param token The token to distribute
     * @param swapRouter The swap router to use
     * @param fee The fee for the pool to swap through
     */
    function distribute(
        IMadSBT madSBT,
        uint256 revShareAmount,
        uint256 collectionId,
        address token,
        address swapRouter,
        uint24 fee
    ) public {
        address rewardsToken = madSBT.rewardsToken();
        address underlying = ISuperToken(rewardsToken).getUnderlyingToken();

        // check if token is underlying
        if (token != underlying) {
            // swap token to underlying
            revShareAmount = swapExactInputAmount(token, underlying, swapRouter, revShareAmount, fee);
        }

        // wrap as super usdc
        IERC20(underlying).approve(rewardsToken, revShareAmount);
        ISuperToken(rewardsToken).upgrade(revShareAmount);

        // instant distribution
        IERC20(rewardsToken).approve(address(madSBT), revShareAmount);
        madSBT.distributeRewards(collectionId, revShareAmount);
    }

    /**
     * @dev Swap one currency for another, for exactly `outputAmount` of `tokenOut`
     * @param tokenIn The token to swap from
     * @param tokenOut The token to swap to
     * @param swapRouter The swap router to use
     * @param amountInMaximum The maximum input amount of `tokenIn`
     * @param outputAmount The exact output amount desired of `tokenOut`
     * @param fee The fee for the pool to swap through
     * @return deltaAmountIn The delta between `amountInMaximum` and what was actually needed - to be refunded
     */
    function swapForExactOutputAmount(
        address tokenIn,
        address tokenOut,
        address swapRouter,
        uint256 amountInMaximum,
        uint256 outputAmount,
        uint24 fee
    ) public returns (uint256 deltaAmountIn) {
        ISwapRouter uniswapV3Router = ISwapRouter(swapRouter);

        IERC20(tokenIn).approve(address(uniswapV3Router), amountInMaximum);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee, // 500, 3000, 10000
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountOut: outputAmount,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        uint256 amountIn = uniswapV3Router.exactOutputSingle(params);

        // `amountInMaximum` may not have all been spent
        if (amountIn < amountInMaximum) {
            // reduce the approved balance, and caller should refund `deltaAmountIn`
            IERC20(tokenIn).approve(address(uniswapV3Router), 0);
            deltaAmountIn = amountInMaximum - amountIn;
        }
    }

    /**
     * @dev Swap one currency for another, exactly `amountIn` of `tokenIn`
     * @param tokenIn The token to swap from
     * @param tokenOut The token to swap to
     * @param swapRouter The swap router to use
     * @param amountIn The input amount of `tokenIn`
     * @param fee The fee for the pool to swap through
     * @return amountOut The amount of the received token
     */
    function swapExactInputAmount(
        address tokenIn,
        address tokenOut,
        address swapRouter,
        uint256 amountIn,
        uint24 fee
    ) public returns (uint256 amountOut) {
        ISwapRouter uniswapV3Router = ISwapRouter(swapRouter);

        IERC20(tokenIn).approve(address(uniswapV3Router), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee, // 500, 3000, 10000
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amountOut = uniswapV3Router.exactInputSingle(params);
    }
}
