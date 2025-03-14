# $MAD Stablecoin Protocol

$MAD (**Mint Against Deposit**) Stablecoin Protocol is an immutable, governance-less and singleton-contract protocol for minting stablecoins fully backed by native tokens.

## Development

The entire protocol is written in a single <500 LOC file `MAD.sol`. The interface file `IMAD.sol` is thoroughly annotated, and the protocol is documented in the README as well.

### Install

This repo is a foundry project. Refer to the foundry documentation for CLI installation instructions: https://book.getfoundry.sh/

This repo uses Solady as a dependency. Install it by running:

```bash
forge install
```

### Build

```shell

$ forge build

```

### Test ( ⚠️ )

**NOTE:** There are currently no tests. I'm working on it!

```shell

$ forge test

```

## Protocol

### Minting Stablecoins

A user creates a position by depositing native token collateral and borrows $MAD token units equivalent to 90% of the USD value of the collateral.

All borrows are interest-free. The user is charged a one-time borrow fee upon creating a position. The borrow fee is calculated based on a dynamic rate 1% $< r <$ 5% as $loan \times r$.

The user can withdraw or supply collateral to a position to maintain its LTV ("Loan-To-Value") below 90%, calculated as `position_debt / position_collateral`.

### Redeem Stablecoins for native tokens

The protocol allows users to redeem native tokens in exchange for $MAD close to the native token's USD price. This maintains a soft peg of $DUSD at $1 USD.

Users are charged a redemption fee based on a dynamic rate 0.5% $< r <$ 5% as $redemption \times r$.

### Fee Rates

Both "borrow fee" and "redemption fee" rates are tracked by the same single rate variable i.e. "variable rate".

Redemptions increase the circulating native token supply which may be a precursor to sell pressure on native tokens, and thus, a possible reduction of the USD value of the total collateral held by the protocol.

Therefore, the variable rate increases when redemptions occur, making both borrowing and redemptions more expensive. The base rate decays to 0 over time with a 6 hour half life.

The variable rate for a redemption is calculated as:
$$r(t) = r(t-1) \times \delta^{\Delta t}$$
where $r(t-1)$ is the variable rate at the last redemption, $\delta$ is the hourly decay rate (0.89) and $t$ is the hours passed since the previous redemption.

The variable rate is initialized as zero and is incremented on each redemption as follows:
$$r(t) = r(t-1) + \alpha \cdot \frac{m}{n}$$
where $\alpha$ is 1%, $m$ is the $MAD redeemed and $n$ is the total $MAD supply.

The variable rate is capped at 4%, and the fee rate charged at borrows and redemptions is 1% plus the variable rate, capping the maximum fee rate at 5%.

### Insurance Reserve

The protocol holds $MAD in an Insurance Reserve. This $MAD is used to pay debt and liquidation incentive in the appropriate liquidation scenarios.

Since there is no central governance or privileged actors in the protocol, this reserve starts at zero and is expected to be filled by user deposits of $MAD.

Users who deposit $MAD in the Insurance Reserve earn native tokens collateral generated in liquidations, in proportion to their deposit's share of the Insurance Reserve.

### Liquidations

Any user can liquidate an unhealthy position -- a position with collateral ratio (`debt / collateral`) above than 90% -- and receive 1% of the collateral as compensation.

Upon liquidation, the native token collateral of the position is rewarded to the Insurance Reserve depositors based on their deposit's share in the reserve.

The protocol stores the following information for a position:

```solidity
struct Position {
	uint256 id;
	address owner;
	uint256 debtPoints;
	uint256 collateralPoints;
}
```

The protocol uses a point-based accounting system to efficiently handle liquidations and potential socialization of losses. This avoids expensive gas costs of iterating through all positions during redistribution events.

For each position:

- Actual debt = `(debt_points * debt_per_debt_point)`

* Actual collateral = `(collateral_points * collateral_per_collateral_point)`

When a position is liquidated:

1. The system attempts to use the insurance reserve to cover the position's debt and pay the liquidator's incentive
2. If the insurance reserve is sufficient, other positions remain unaffected.
3. If the insurance reserve is insufficient, the liquidated position's debt and collateral are proportionally redistributed across all remaining positions by updating the global accounting variables:

- `debt_per_debt_point += (position_debt / total_system_debt_points)`
- `collateral_per_collateral_point += (position_collateral / total_system_collateral_points)`

This approach enables gas-efficient redistribution without iterating through all positions, as each position's actual debt and collateral are calculated on-demand when the position is accessed.

### Thresholds

If the Total Collateral Ratio (TCR) of the protocol (i.e. total protocol held collateral / total circulating $MAD) drops below 110%, the protocol prohibits any activity (e.g. borrowing or withdrawing collateral) that would further reduce the TCR.

## Feedback

Please open an issue or PR with any feedback, or contact me on X ([@MonkeyMeaning](https://x.com/MonkeyMeaning))
