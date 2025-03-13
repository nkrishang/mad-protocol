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

interface IMad {}
