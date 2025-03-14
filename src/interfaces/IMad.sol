// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @dev Position struct: Tracks a user's borrowed stablecoins ($MAD) against deposited collateral.
 *
 *      The protocol uses a point-based accounting system to efficiently handle liquidations and
 *      potential socialization of losses. This avoids expensive gas costs of iterating through
 *      all positions during redistribution events.
 *
 *      For each position:
 *      - Actual debt = (debt_points * lifetime_debt_per_point)
 *      - Actual collateral = (collateral_points * lifetime_collateral_per_point)
 *
 *      When a position is liquidated:
 *      1. The system attempts to use the insurance reserve to cover the position's debt and pay
 *         the liquidator's incentive
 *      2. If the insurance reserve is sufficient, other positions remain unaffected
 *      3. If the insurance reserve is insufficient, the liquidated position's debt and collateral
 *         are proportionally redistributed across all remaining positions by updating the global
 *         accounting variables:
 *
 *         lifetime_debt_per_point += (position_debt / total_system_debt_points)
 *         lifetime_collateral_per_point += (position_collateral / total_system_collateral_points)
 *
 *      This approach enables gas-efficient redistribution without iterating through all positions,
 *      as each position's actual debt and collateral are calculated on-demand when the position
 *      is accessed.
 *
 * @param id                  Unique position identifier
 * @param owner               Address of the position owner
 * @param debtPoints          Position's debt points (includes borrowed $MAD, liquidation reserve, and borrow fee)
 * @param collateralPoints    Position's collateral points
 */
struct Position {
    uint256 id;
    address owner;
    uint256 debtPoints;
    uint256 collateralPoints;
}

interface IMADBase {
    /**
     * @notice Mint new $MAD stablecoins by depositing collateral and borrowing against it.
     *
     * @dev The collateral is denominated in wrapped native token (e.g. WETH). The caller (msg.sender) must approve
     *      the contract to transfer `collateral` amount of native token before calling this function.
     *
     *      The `mint` operation checks the following conditions:
     *          - Checks that the caller is providing at least min. collateral value of 2000 USD worth of native tokens.
     *          - Checks that the caller is not borrowing more than 90% of the collateral value in $MAD stablecoins.
     *          - Checks that the Total Collateral Ratio (TCR = system_collateral / system_debt) is above 110% before and
     *            after the debt created by the `mint` operation.
     *
     *      The caller is charged a one-time borrow fee and their position `debt` is `borrow` + fee. The LTV of the position
     *      is calculated using total debt as `debt / collateral`, which must be less than 90%. Similarly, the TCR of the
     *      system is calculated using the total debt as ((system_collateral + collateral) / (system_debt + debt)), which
     *      must be above 110%.
     *
     * @param collateral The amount of native token deposit to borrow against.
     * @param borrow The amount of $MAD stablecoins to borrow.
     * @param recipient The recipient of the minted $MAD stablecoins.
     */
    function mint(uint256 collateral, uint256 borrow, address recipient) external;

    /**
     * @notice Close a position by repaying $MAD debt in exchange for the position's collateral.
     *
     * @dev The caller (msg.sender) must be the owner of the position.
     *
     *      The `close` operation burns the caller's $MAD debt and transfers the position's collateral to the `recipient`.
     *
     *      The `close` operation checks the following conditions:
     *          - Checks that the position exists.
     *          - Checks that the caller is the owner of the position.
     *          - Checks that the position is healthy i.e. the LTV of the position is below 90%.
     *
     * @param positionId The unique identifier of the position to close.
     * @param recipient The recipient of the position's collateral.
     */
    function close(uint256 positionId, address recipient) external;

    /**
     * @notice Withdraw native token collateral from a position.
     *
     * @dev The caller (msg.sender) must be the owner of the position.
     *
     *      The `withdrawCollateral` operation transfers `collateral` amount of native token from the contract to `recipient`.
     *
     *      The `withdrawCollateral` operation checks the following conditions:
     *          - Checks that the position exists.
     *          - Checks that the caller is the owner of the position.
     *          - Checks that the position has more collateral than the amount being withdrawn.
     *          - Checks that the position is healthy i.e. LTV is below 90% after the withdrawal.
     *          - Checks that the TCR of the system is above 110% after the withdrawal.
     *
     * @param positionId The unique identifier of the position.
     * @param collateral The amount of native token collateral to withdraw.
     * @param recipient The recipient of the withdrawn collateral.
     */
    function withdrawCollateral(uint256 positionId, uint256 collateral, address recipient) external;

    /**
     * @notice Supply native token collateral to a position.
     *
     * @dev The caller (msg.sender) must approve the contract to transfer `collateral` amount of wrapped native tokens.
     *
     *      The `supplyCollateral` operation checks the following conditions:
     *          - Checks that the position exists.
     *
     * @param positionId The unique identifier of the position.
     * @param collateral The amount of native token collateral to supply.
     */
    function supplyCollateral(uint256 positionId, uint256 collateral) external;

    /**
     * @notice Redeem $MAD stablecoins in exchange for an equivalent USD value in native tokens.
     *
     * @dev The caller (msg.sender) must own at least `amount` $MAD tokens.
     *
     *      The `redeem` operation burns `amount` tokens from the caller's balance and sends an equivalent USD value
     *      in wrapped native tokens from the contract's balance.
     *
     *      The caller is charged a redemption fee in $MAD, which is transferred to the contract.
     *
     * @param amount The amount of $MAD stablecoin to redeem.
     * @param recipient The recipient of the native tokens.
     */
    function redeem(uint256 amount, address recipient) external;

    /**
     * @notice Liquidate an unhealthy position (i.e. LTV greater than 90%)
     *
     * @dev The `liquidate` operation closes a position and releases its collateral, all without repaying $MAD debt.
     *      This leaves the $MAD tokens originally minted against the position's collateral as unbacked.
     *
     *      The contract's $MAD balance up to the position's debt is burned, and a proportionate amount of the position's
     *      collateral is rewarded to stakers in the system's insurance reserve (since they contribute to the contract's)
     *      $MAD token balance.
     *
     *      The system distributes any remainder position debt and collateral equally amongst all other positions.
     *
     *      The liquidator is paid 1 percent of the total position collateral as an incentive reward.
     *
     *      The `liquidate` operation checks the following conditions:
     *          - Checks that the position exists.
     *          - Checks whether the position is unhealthy i.e. LTV is above 90%.
     *
     * @param positionId The unique identifier of the position.
     * @param recipient The recipient of the liquidation reward.
     */
    function liquidate(uint256 positionId, address recipient) external;

    /**
     * @notice Stake $MAD tokens in the insurance reserve.
     *
     * @dev The `stake` operation transfers `amount` of $MAD tokens from the caller (msg.sender) to the contract. The
     *      token's in the contract's balance are only used for being burned in the event of a liquidation.
     *
     * @param amount The amount of $MAD tokens to stake.
     */
    function stake(uint256 amount) external;

    /**
     * @notice Unstake $MAD tokens from the insurance reserve.
     *
     * @dev The `unstake` operation transfers $MAD tokens from the contract to the caller (msg.sender).
     *
     *      The amount of $MAD token released to the staker is `contract_balance * (user_stake / total_staked)`.
     *      The staker may receive less $MAD tokens than they originally staked since the contract balance is meant
     *      to be burned in liquidations. However, the staker also receives their portion of native token rewards
     *      earned by the insurance reserve in liquidations.
     */
    function unstake() external;

    /**
     * @notice Claim native token stake rewards from the insurance reserve.
     *
     * @dev The `claimRewards` operation transfer native tokens from the contract to the caller (msg.sender)
     *      in proportion to their $MAD token stake contribution to the insurance reserve.
     *
     *      The `claimRewards` does not unstake $MAD tokens from the insurance reserve.
     *
     */
    function claimRewards() external;
}
