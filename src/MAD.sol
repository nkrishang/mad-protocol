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

    error PositionDNE();
    error LTVInBounds();
    error TCROutOfBounds();
    error LTVOutOfBounds();
    error InsufficientCollateral();

    // =============================================================//
    //                            EVENTS                            //
    // =============================================================//

    event Mint(uint256 indexed id, address indexed owner, uint256 debt, uint256 collateral);

    event Supply(uint256 indexed id, uint256 collateral);

    event Withdraw(uint256 indexed id, uint256 collateral);

    event Redeem(address indexed owner, uint256 burned, uint256 redeemed);

    event Stake(address indexed owner, uint256 amount);

    event Unstake(address indexed owner, uint256 amount);

    event ClaimRewards(address indexed owner, uint256 amount);

    // =============================================================//
    //                           CONSTANTS                          //
    // =============================================================//

    uint256 public constant MIN_COLLATERAL_VALUE_UNSCALED = 2000;

    uint256 public constant REFUNDABLE_LIQUIDATION_RESERVE_SCALED = 200 ether;

    int256 public constant DECAY_RATE_SCALED = 0.89 ether;
    uint256 public constant BASE_FEE_RATE_BPS = 0.01 ether;
    uint256 public constant MAX_VARIABLE_FEE_RATE_BPS = 0.04 ether;

    // =============================================================//
    //                          IMMUTABLES                          //
    // =============================================================//

    IOracle public immutable PRICE_ORACLE;

    WETH public immutable WRAPPED_NATIVE_TOKEN;

    // =============================================================//
    //                           STORAGE                            //
    // =============================================================//

    uint256 public variableFeeRate;
    uint256 public lastFeeUpdateTimestamp;

    uint256 public totalSystemDebtPoints;
    uint256 public lifetimeDebtPerDebtPoint;
    uint256 public totalSystemCollateralPoints;
    uint256 public lifetimeCollateralPerCollateralPoint;

    uint256 public nextPositionId;

    uint256 public totalStaked;
    uint256 public lifetimeRewardPerMAD;

    mapping(uint256 id => Position data) public positions;
    mapping(address staker => uint256 stakeAmount) public staked;
    mapping(address staker => uint256 rewardDebt) public rewardDebt;

    // =============================================================//
    //                            MINT                              //
    // =============================================================//

    function mint(uint256 collateral, uint256 borrow, address onBehalf, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Check whether provided collateral is GTE minimum collateral value. (e.g. 2000 USD)
        require(collateral.mulWad(priceWAD) >= MIN_COLLATERAL_VALUE_UNSCALED * 1 ether, InsufficientCollateral());

        // Check whether Total Collateral Ratio (TCR) is above 110%.
        uint256 totalSystemDebt = totalSystemDebtPoints.mulWad(lifetimeDebtPerDebtPoint);
        uint256 totalSystemCollateral = totalSystemCollateralPoints.mulWad(lifetimeCollateralPerCollateralPoint);

        require(totalSystemCollateral.mulWad(priceWAD).divWad(totalSystemDebt) > 1.1 ether, TCROutOfBounds());

        // Check whether LTV ( deb/collateral ) is less than max LTV 90%
        require(borrow.divWad(collateral.mulWad(priceWAD)) < 0.9 ether, LTVOutOfBounds());

        // Check whether TCR post-debt is above 110%
        require(
            (totalSystemCollateral + collateral).mulWad(priceWAD).divWad(totalSystemDebt + borrow) > 1.1 ether,
            TCROutOfBounds()
        );

        // Calculate full debt (borrow + fees)
        uint256 debt = borrow + _getFeeRateWAD(0).mulWad(borrow) + REFUNDABLE_LIQUIDATION_RESERVE_SCALED;

        // Calculate cancelled collateral and debt
        uint256 cancelledDebt = lifetimeDebtPerDebtPoint.mulWad(borrow);
        uint256 cancelledCollateral = lifetimeCollateralPerCollateralPoint.mulWad(collateral);

        // Increment lifetime collateral and debt accrued per point.
        lifetimeDebtPerDebtPoint++;
        lifetimeCollateralPerCollateralPoint++;

        // Update total system debt and collateral.
        totalSystemDebtPoints += debt;
        totalSystemCollateralPoints += collateral;

        // Get the next position ID.
        uint256 id = nextPositionId++;

        // Create and store position struct.
        positions[id] = Position(id, onBehalf, debt, cancelledDebt, collateral, cancelledCollateral);

        // Pull wrapped native tokens as collateral
        WRAPPED_NATIVE_TOKEN.transferFrom(onBehalf, address(this), collateral);

        // Mint borrow amount of $MAD
        _mint(recipient, borrow);
    }

    // =============================================================//
    //                      COLLATERAL MANAGEMENT                   //
    // =============================================================//

    function withdrawCollateral(uint256 positionId, uint256 collateral, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Get position details.
        Position memory pos = positions[positionId];

        // Check whether position exists.
        require(pos.collateralPoints > 0, PositionDNE());

        // Calculate real position collateral.
        uint256 cPerPoint = lifetimeCollateralPerCollateralPoint;
        uint256 posCollateral = cPerPoint.mulWad(pos.collateralPoints) - pos.cancelledCollateral;

        // Check whether requested collateral is less than real collateral.
        require(collateral <= posCollateral, InsufficientCollateral());

        // Check whether LTV is below 90%.
        uint256 posDebt = lifetimeDebtPerDebtPoint.mulWad(pos.debtPoints) - pos.cancelledDebt;
        require(posDebt.divWad((posCollateral - collateral).mulWad(priceWAD)) < 0.9 ether, LTVOutOfBounds());

        // Calculate collateral points to be withdrawn.
        uint256 withdrawnCollateralPoints = collateral.divWad(cPerPoint);

        // Check whether TCR post-withdrawal is above 110%
        require(
            (totalSystemCollateralPoints - withdrawnCollateralPoints).mulWad(priceWAD).divWad(totalSystemDebtPoints)
                > 1.1 ether,
            TCROutOfBounds()
        );

        // Decrement position collateral points.
        positions[positionId].collateralPoints -= withdrawnCollateralPoints;

        // Decrement total system collateral points.
        totalSystemCollateralPoints -= withdrawnCollateralPoints;

        // Transfer collateral to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, collateral);

        emit Supply(positionId, collateral);
    }

    function supplyCollateral(uint256 positionId, uint256 collateral, address onBehalf) external {
        // Get position details.
        Position memory pos = positions[positionId];

        // Check whether position exists.
        require(pos.collateralPoints > 0, PositionDNE());

        // Calculate cancelled collateral and debt
        uint256 cancelledCollateral = lifetimeCollateralPerCollateralPoint.mulWad(collateral);

        // Increment lifetime collateral accrued per point.
        lifetimeCollateralPerCollateralPoint++;

        // Update total system collateral.
        totalSystemCollateralPoints += collateral;

        // Update position's collateral points.
        positions[positionId].collateralPoints += collateral;
        positions[positionId].cancelledCollateral += cancelledCollateral;

        // Pull wrapped native tokens as collateral
        WRAPPED_NATIVE_TOKEN.transferFrom(onBehalf, address(this), collateral);

        emit Supply(positionId, collateral);
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
    //                          LIQUIDATE                           //
    // =============================================================//

    function liquidate(uint256 positionId, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Get position details.
        Position memory pos = positions[positionId];

        // Check whether position exists.
        require(pos.collateralPoints > 0, PositionDNE());

        // Calculate LTV.
        uint256 posDebt = lifetimeDebtPerDebtPoint.mulWad(pos.debtPoints) - pos.cancelledDebt;
        uint256 posCollateral =
            lifetimeCollateralPerCollateralPoint.mulWad(pos.collateralPoints) - pos.cancelledCollateral;

        // Check whether LTV is above 90%.
        require(posDebt.divWad(posCollateral.mulWad(priceWAD)) >= 0.9 ether, LTVInBounds());

        // Calculate liquidation reward in collateral.
        uint256 liquidationCollateralReward = posCollateral.mulWad(BASE_FEE_RATE_BPS);

        // Cover as much debt as possible from insurance reserve.
        uint256 systemBalance = balanceOf(address(this));
        uint256 insured = systemBalance > posDebt ? posDebt : systemBalance;

        if (insured > 0) {
            // Transfer liquidation reserve from system to recipient.
            transfer(recipient, REFUNDABLE_LIQUIDATION_RESERVE_SCALED);

            // Burn remainder debt amount of $MAD from system reserve.
            _burn(address(this), insured - REFUNDABLE_LIQUIDATION_RESERVE_SCALED);

            // Compensate system with collateral.
            lifetimeRewardPerMAD += (posCollateral - liquidationCollateralReward).divWadUp(totalStaked);
        } else {
            // Distribute debt across positions.
            lifetimeDebtPerDebtPoint += posDebt.divWad(totalSystemDebtPoints);

            // Distribute collateral across positions.
            lifetimeCollateralPerCollateralPoint +=
                (posCollateral - liquidationCollateralReward).divWad(totalSystemCollateralPoints);

            // Mint liquidation reserve from system to recipient.
            _mint(recipient, REFUNDABLE_LIQUIDATION_RESERVE_SCALED);
        }

        // Transfer liquidation reward in collateral to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, liquidationCollateralReward);

        // Delete position.
        delete positions[positionId];
    }

    // =============================================================//
    //                            STAKE                             //
    // =============================================================//

    function stake(uint256 amount, address onBehalf) external {
        // Update staker reward debt with rewards missed by amount being staked just now.
        rewardDebt[onBehalf] = lifetimeRewardPerMAD.mulWadUp(amount);

        // Update total staked amount.
        totalStaked += amount;

        // Update staker's stake amount.
        staked[onBehalf] += amount;

        // Transfer $MAD stake to the system.
        transferFrom(onBehalf, address(this), amount);

        emit Stake(onBehalf, amount);
    }

    function unstake(address onBehalf) external {
        // Get staker's stake amount and reward debt.
        uint256 stakeAmount = staked[onBehalf];
        uint256 debt = rewardDebt[onBehalf];

        // Calculate rewards earned by staker.
        uint256 rewardPerMAD = lifetimeRewardPerMAD;
        uint256 totalRewards = rewardPerMAD.mulWad(stakeAmount) - debt;

        // Update staker's reward debt.
        rewardDebt[onBehalf] += totalRewards;

        // Calculate withdraw amount.
        uint256 withdrawAmount = balanceOf(address(this)).mulWad(stakeAmount).divWad(totalStaked);

        // Update total staked amount.
        totalStaked -= stakeAmount;

        // Reset staker's stake amount.
        delete staked[onBehalf];

        // Transfer rewards to staker.
        WRAPPED_NATIVE_TOKEN.transfer(onBehalf, totalRewards);

        // Transfer $MAD stake to the staker.
        _transfer(address(this), onBehalf, withdrawAmount);

        emit Unstake(onBehalf, withdrawAmount);
    }

    function claimRewards(address onBehalf) external {
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

    // =============================================================//
    //                            PRICE                             //
    // =============================================================//

    function _getPriceWAD() private view returns (uint256) {
        return PRICE_ORACLE.price() * (1 ether / PRICE_ORACLE.scale());
    }

    // =============================================================//
    //                         FEE RATE                             //
    // =============================================================//

    function _getFeeRateWAD(uint256 redeemAmount) private returns (uint256) {
        // Variable fee rate is calculated as `r(n) = r(n-1) * (decay ^ hoursElapsed)`.
        uint256 currentVariableRate = variableFeeRate.mulWadUp(
            uint256(DECAY_RATE_SCALED.powWad(int256((block.timestamp - lastFeeUpdateTimestamp) / 1 hours)))
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
            lastFeeUpdateTimestamp = block.timestamp;
        }

        return BASE_FEE_RATE_BPS + currentVariableRate;
    }

    // =============================================================//
    //                        ERC20 METADATA                        //
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
