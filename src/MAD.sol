// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Position} from "./interfaces/IMad.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {WETH} from "lib/solady/src/tokens/WETH.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

contract MAD is ERC20 {
    // =============================================================//
    //                             LIB                              //
    // =============================================================//

    using FixedPointMathLib for int256;
    using FixedPointMathLib for uint256;

    // =============================================================//
    //                            ERRORS                            //
    // =============================================================//

    /// @notice Emitted when a borrow action pushes the Total Collateral Ratio (TCR) below 110%.
    error TCROutOfBounds();

    /// @notice Emitted when a borrow action pushes the position Loan To Value (LTV) greater than 90%.
    error LTVOutOfBounds();

    /// @notice Emitted when the provided collateral is less than the minimum required value to mint $MAD.
    error InsufficientMintCollateral();

    // =============================================================//
    //                            EVENTS                            //
    // =============================================================//

    /// @notice Emitted when a new $MAD is minted.
    event Mint(uint256 indexed id, address indexed owner, uint256 debt, uint256 collateral);

    /// @notice Emitted when native tokens are redeemed for $MAD.
    event Redeem(address indexed owner, uint256 burned, uint256 redeemed);

    /// @notice Emitted when $MAD is staked.
    event Stake(address indexed owner, uint256 amount);

    /// @notice Emitted when staker claims rewards.
    event ClaimRewards(address indexed owner, uint256 amount);

    // =============================================================//
    //                           CONSTANTS                          //
    // =============================================================//

    // ========================= Fee Rates =========================//

    /// @notice The decay rate constant for half life of 6 hours.
    int256 public constant DECAY_RATE_SCALED = 0.89 ether;

    /// @notice The base fee rate for mints and redemptions (1 percent).
    uint256 public constant BASE_FEE_RATE_BPS = 0.01 ether;

    /// @notice The maximum fee rate for mints and redemptions (4 percent).
    uint256 public constant MAX_VARIABLE_FEE_RATE_BPS = 0.04 ether;

    // ========================= Collateral =========================//

    /// @notice The minimum collateral value in USD required to mint $MAD.
    uint256 public constant MIN_COLLATERAL_VALUE_UNSCALED = 2000;

    /// @notice The fixed refundable debt amount reserved for liquidation incentive.
    uint256 public constant REFUNDABLE_LIQUIDATION_RESERVE_SCALED = 200 ether;

    // =============================================================//
    //                          IMMUTABLES                          //
    // =============================================================//

    /// @notice Address of the price oracle contract.
    IOracle public immutable PRICE_ORACLE;

    /// @notice Address of the canonical native token wrapper contract.
    WETH public immutable WRAPPED_NATIVE_TOKEN;

    // =============================================================//
    //                           STORAGE                            //
    // =============================================================//

    // ========================= Fee Rates =========================//

    /// @notice The variable fee rate for mints and redemptions.
    uint256 public variableFeeRate;

    /// @notice The timestamp when a redemption last occured.
    uint256 public lastRedemptionTimestamp;

    // ========================= Positions ==========================//

    /// @notice The ID assigned to the next new position created.
    uint256 public nextPositionId;

    /// @notice Maps a position ID => position id, owner, collateral and debt.
    mapping(uint256 id => Position pos) public positions;

    // ===================== Insurance Reserve ======================//

    uint256 public unpaidRewardPool;
    uint256 public unaccountedRewardPool;
    uint256 public lifetimeRewardPerMAD;
    uint256 public totalStaked;

    mapping(address staker => uint256 stakeAmount) public staked;
    mapping(address staker => uint256 rewardDebt) public rewardDebt;

    // =============================================================//
    //                            MINT                              //
    // =============================================================//

    function mint(uint256 collateral, uint256 borrow, address onBehalf, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Check whether provided collateral is GTE minimum collateral value. (e.g. 2000 USD)
        require(collateral.mulWad(priceWAD) >= MIN_COLLATERAL_VALUE_UNSCALED * 1 ether, InsufficientMintCollateral());

        // Check whether Total Collateral Ratio (TCR) is above 110%.
        uint256 pCollateral = WRAPPED_NATIVE_TOKEN.balanceOf(address(this));
        uint256 pDebt = totalSupply();

        require((pCollateral.mulWad(priceWAD)).divWad(pDebt) > uint256(110 ether).divWad(100 ether), TCROutOfBounds());

        // Check whether LTV ( deb/collateral ) is less than max LTV 90%
        require(borrow.divWad(collateral) < uint256(90 ether).divWad(100 ether), LTVOutOfBounds());

        // Check whether TCR post-debt is above 110%
        require(
            (pCollateral + collateral).mulWad(priceWAD).divWad(pDebt + borrow) > uint256(110 ether).divWad(100 ether),
            TCROutOfBounds()
        );

        // Calculate full debt (borrow + fees)
        uint256 debt = borrow + _getFeeRateWAD(0).mulWad(borrow) + REFUNDABLE_LIQUIDATION_RESERVE_SCALED;

        // Get the next position ID.
        uint256 id = nextPositionId++;

        // Create and store position struct.
        positions[id] = Position(id, onBehalf, debt, collateral);

        // Pull wrapped native tokens as collateral
        WRAPPED_NATIVE_TOKEN.transferFrom(onBehalf, address(this), collateral);

        // Mint borrow amount of $MAD
        _mint(recipient, borrow);

        emit Mint(id, onBehalf, debt, collateral);
    }

    // =============================================================//
    //                            REDEEM                            //
    // =============================================================//

    function redeem(uint256 amount, address recipient, address onBehalf) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Calculate fees amount.
        uint256 fees = _getFeeRateWAD(amount).mulWadUp(amount);

        // Calculate native token redemption value.
        uint256 nativeTokenValue = (amount - fees).divWad(priceWAD);

        // Transfer $MAD fees to the system.
        _transfer(onBehalf, address(this), fees);

        // Burn redeemed $MAD.
        _burn(onBehalf, (amount - fees));

        // Transfer native tokens to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, nativeTokenValue);

        emit Redeem(onBehalf, amount, nativeTokenValue);
    }

    // =============================================================//
    //                            STAKE                             //
    // =============================================================//

    function stake(uint256 amount, address onBehalf) external {
        // Update staker reward debt with rewards missed by amount being staked just now.
        rewardDebt[onBehalf] = lifetimeRewardPerMAD.mulWadUp(amount);

        // Accrue rewards and update lifetime reward per $MAD.
        _accountRewards();

        // Update total staked amount.
        totalStaked += amount;

        // Update staker's stake amount.
        staked[onBehalf] += amount;

        // Transfer $MAD stake to the system.
        transferFrom(onBehalf, address(this), amount);

        emit Stake(onBehalf, amount);
    }

    function unstake(uint256 amount, address onBehalf) external {
        // Accrue rewards and update lifetime reward per $MAD.
        _accountRewards();

        // Get staker's stake amount and reward debt.
        uint256 stakeAmount = staked[onBehalf];
        uint256 debt = rewardDebt[onBehalf];

        // Calculate rewards earned by staker.
        uint256 rewardPerMAD = lifetimeRewardPerMAD;
        uint256 totalRewards = rewardPerMAD.mulWad(stakeAmount) - debt;

        // Update staker's reward debt.
        rewardDebt[onBehalf] += totalRewards;

        // Update total staked amount.
        totalStaked -= amount;

        // Update staker's stake amount.
        staked[onBehalf] -= amount;

        // Transfer rewards to staker.
        WRAPPED_NATIVE_TOKEN.transfer(onBehalf, totalRewards);

        // Transfer $MAD stake to the staker.
        _transfer(address(this), onBehalf, amount);

        emit Stake(onBehalf, amount);
    }

    function claimRewards(address onBehalf) external {
        // Accrue rewards and update lifetime reward per $MAD.
        _accountRewards();

        // Get staker's stake amount and reward debt.
        uint256 stakeAmount = staked[onBehalf];
        uint256 debt = rewardDebt[onBehalf];

        // Calculate rewards earned by staker.
        uint256 rewardPerMAD = lifetimeRewardPerMAD;
        uint256 totalRewards = rewardPerMAD.mulWad(stakeAmount) - debt;

        // Update staker's reward debt.
        rewardDebt[onBehalf] += totalRewards;

        // Transfer rewards to staker.
        WRAPPED_NATIVE_TOKEN.transfer(onBehalf, totalRewards);

        emit ClaimRewards(onBehalf, totalRewards);
    }

    function _accountRewards() private {
        // Get unpaid and unaccounted reward pools, and current native token balance.
        uint256 unpaidPool = unpaidRewardPool;
        uint256 unaccountedPool = unaccountedRewardPool;
        uint256 currentBalance = WRAPPED_NATIVE_TOKEN.balanceOf(address(this));

        // Add any excess native tokens to the unpaid reward pool.
        if (currentBalance > (unpaidPool + unaccountedPool)) {
            unpaidPool += currentBalance - (unpaidPool + unaccountedPool);
        }

        // Update rewards earned per 1 staked $MAD with 1 token's stake in unaccounted rewards.
        lifetimeRewardPerMAD += unaccountedPool.divWadUp(totalStaked);

        // Move unaccounted rewards to unpaid reward pool.
        unpaidRewardPool += unaccountedPool;
        delete unaccountedRewardPool;
    }

    // =============================================================//
    //                         FEE RATE                             //
    // =============================================================//

    /// @dev Returns the fee rate for minting or redeeming $MAD.
    function _getFeeRateWAD(uint256 redeemAmount) private returns (uint256) {
        // Variable fee rate is calculated as `r(n) = r(n-1) * (decay ^ hoursElapsed)`.
        uint256 currentVariableRate = variableFeeRate.mulWadUp(
            uint256(DECAY_RATE_SCALED.powWad(int256((block.timestamp - lastRedemptionTimestamp) / 1 hours)))
        );

        if (redeemAmount > 0) {
            // On redemptions, variable rate is incremented as `r += base_fee * (redeemAmount / totalSupply)`.
            uint256 nextVariableRate =
                currentVariableRate + BASE_FEE_RATE_BPS.mulWadUp(redeemAmount.divWadUp(totalSupply()));

            // The variable fee rate is caped at 4 percent.
            if (nextVariableRate > MAX_VARIABLE_FEE_RATE_BPS) {
                nextVariableRate = MAX_VARIABLE_FEE_RATE_BPS;
            }

            variableFeeRate = nextVariableRate;
            lastRedemptionTimestamp = block.timestamp;
        }

        return BASE_FEE_RATE_BPS + currentVariableRate;
    }

    // =============================================================//
    //                           PRICE                              //
    // =============================================================//

    /// @dev Returns the price of 1 native token in USD, scaled by 1e18.
    function _getPriceWAD() private view returns (uint256) {
        return PRICE_ORACLE.price() * (1 ether / PRICE_ORACLE.scale());
    }

    // =============================================================//
    //                       ERC20 METADATA                         //
    // =============================================================//

    /// @dev Returns the name of the token.
    function name() public pure override returns (string memory) {
        return "Mint Against Deposit";
    }

    /// @dev Returns the symbol of the token.
    function symbol() public pure override returns (string memory) {
        return "MAD";
    }
}
