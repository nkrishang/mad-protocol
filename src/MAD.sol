// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Position} from "./interfaces/IMad.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {WETH} from "lib/solady/src/tokens/WETH.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/**
 * @title $MAD Stablecoin Protocol (Mint Against Deposit)
 * @author github.com/nkrishang
 * @notice Immutable, governance-less, singleton-contract protocol for minting stablecoins fully backed by native tokens.
 *
 * Inspired by Morpho (https://github.com/morpho-org/morpho-blue) and Liquity (https://github.com/liquity/dev).
 */
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
    error UnauthorizedCaller();
    error InsufficientCollateral();

    // =============================================================//
    //                            EVENTS                            //
    // =============================================================//

    event Redeem(address indexed owner, uint256 burned, uint256 redeemed);
    event Mint(uint256 indexed id, address indexed owner, uint256 debt, uint256 collateral);
    event Close(uint256 indexed id, address indexed owner, uint256 debt, uint256 collateral);

    event Supply(uint256 indexed id, uint256 collateral);
    event Withdraw(uint256 indexed id, uint256 collateral);

    event Liquidate(uint256 indexed id, address indexed liquidator, uint256 debt, uint256 collateral);

    event Stake(address indexed owner, uint256 amount);
    event Unstake(address indexed owner, uint256 amount);
    event ClaimRewards(address indexed owner, uint256 amount);

    // =============================================================//
    //                           CONSTANTS                          //
    // =============================================================//

    uint256 public constant MIN_COLLATERAL_VALUE_UNSCALED = 2000;

    uint256 public constant DECAY_RATE_SCALED = 0.89 ether;
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
    uint256 public totalSystemCollateralPoints;

    uint256 public debtPerDebtPoint;
    uint256 public collateralPerCollateralPoint;

    uint256 public nextPositionId;

    uint256 public totalStaked;
    uint256 public lifetimeRewardPerMAD;

    mapping(uint256 id => Position data) public positions;
    mapping(address staker => uint256 stakeAmount) public staked;
    mapping(address staker => uint256 rewardDebt) public rewardDebt;

    // =============================================================//
    //                         CONSTRUCTOR                          //
    // =============================================================//

    constructor(IOracle oracle, WETH wrapper) {
        PRICE_ORACLE = oracle;
        WRAPPED_NATIVE_TOKEN = wrapper;
    }

    // =============================================================//
    //                            MINT                              //
    // =============================================================//

    function mint(uint256 collateral, uint256 borrow, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Check whether provided collateral is GTE minimum collateral value. (e.g. 2000 USD)
        require(collateral.mulWad(priceWAD) >= MIN_COLLATERAL_VALUE_UNSCALED * 1 ether, InsufficientCollateral());

        // Calculate full debt (borrow + fees)
        uint256 debt = borrow + _getFeeRateWAD(0).mulWadUp(borrow);

        // Check whether LTV ( deb/collateral ) is less than max LTV 90%
        require(debt.divWad(collateral.mulWad(priceWAD)) < 0.9 ether, LTVOutOfBounds());

        // Load system debt and collateral.
        uint256 debtPerPoint = debtPerDebtPoint;
        uint256 collateralPerPoint = collateralPerCollateralPoint;

        // System has not been initalized with any debt or collateral.
        if (debtPerPoint == 0 && collateralPerPoint == 0) {
            // Initialize system debt and collateral per points to 1: In memory and storage
            debtPerPoint = 1;
            collateralPerPoint = 1;

            debtPerDebtPoint = 1;
            collateralPerCollateralPoint = 1;
        } else {
            // If the system is initialized, ensure the system is healthy pre and post borrow.
            uint256 totalSystemDebt = totalSystemDebtPoints.mulWad(debtPerPoint);
            uint256 totalSystemCollateral = totalSystemCollateralPoints.mulWad(collateralPerPoint);

            // Check whether TCR pre-debt is above 110%
            require(totalSystemCollateral.mulWad(priceWAD).divWad(totalSystemDebt) > 1.1 ether, TCROutOfBounds());

            // Check whether TCR post-borrow is above 110%
            require(
                (totalSystemCollateral + collateral).mulWad(priceWAD).divWad(totalSystemDebt + debt) > 1.1 ether,
                TCROutOfBounds()
            );
        }

        // Calculate debt and collateral points.
        uint256 posDebtPoints = debt.divWad(debtPerPoint * 1 ether);
        uint256 posCollateralPoints = collateral.divWad(collateralPerPoint * 1 ether);

        // Update total system debt and collateral.
        totalSystemDebtPoints += posDebtPoints;
        totalSystemCollateralPoints += posCollateralPoints;

        // Get the next position ID.
        uint256 id = nextPositionId++;

        // Create and store position struct.
        positions[id] = Position(id, msg.sender, posDebtPoints, posCollateralPoints);

        // Pull wrapped native tokens as collateral
        WRAPPED_NATIVE_TOKEN.transferFrom(msg.sender, address(this), collateral);

        // Mint borrow amount of $MAD
        _mint(recipient, borrow);
    }

    // =============================================================//
    //                           CLOSE                              //
    // =============================================================//

    function close(uint256 positionId, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Get position details.
        Position memory pos = positions[positionId];

        // Check whether position exists.
        require(pos.owner != address(0), PositionDNE());

        // Check whether closing position as position owner.
        require(pos.owner == msg.sender, UnauthorizedCaller());

        // Calculate real position debt and collateral.
        uint256 posDebt = debtPerDebtPoint.mulWad(pos.debtPoints);
        uint256 posCollateral = collateralPerCollateralPoint.mulWad(pos.collateralPoints);

        // Check whether LTV is below 90%.
        require(posDebt.divWad((posCollateral).mulWad(priceWAD)) < 0.9 ether, LTVOutOfBounds());

        // Delete position.
        delete positions[positionId];

        // Decrement total system collateral and debt points.
        totalSystemDebtPoints -= pos.debtPoints;
        totalSystemCollateralPoints -= pos.collateralPoints;

        // Transfer collateral to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, posCollateral);

        // Burn debt amount of $MAD from system reserve.
        _burn(msg.sender, posDebt);

        emit Close(positionId, msg.sender, posDebt, posCollateral);
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
        require(pos.owner != address(0), PositionDNE());

        // Check whether closing position as position owner.
        require(pos.owner == msg.sender, UnauthorizedCaller());

        // Calculate real position collateral.
        uint256 collateralPerPoint = collateralPerCollateralPoint;
        uint256 posCollateral = collateralPerPoint.mulWad(pos.collateralPoints);

        // Check whether withdrawn collateral is less than position collateral.
        require(collateral < posCollateral, InsufficientCollateral());

        // Check whether post-withdraw LTV is below 90%.
        uint256 debtPerPoint = debtPerDebtPoint;
        uint256 posDebt = debtPerPoint.mulWad(pos.debtPoints);

        require(posDebt.divWad((posCollateral - collateral).mulWad(priceWAD)) < 0.9 ether, LTVOutOfBounds());

        // Check whether TCR post-withdrawal is above 110%
        uint256 totalSystemDebt = totalSystemDebtPoints.mulWad(debtPerPoint);
        uint256 totalSystemCollateral = totalSystemCollateralPoints.mulWad(collateralPerPoint);

        require(
            (totalSystemCollateral - collateral).mulWad(priceWAD).divWad(totalSystemDebt) > 1.1 ether, TCROutOfBounds()
        );

        // Calculate collateral points to be withdrawn.
        uint256 withdrawnCollateralPoints = collateral.divWad(collateralPerPoint);

        // Decrement position collateral points.
        positions[positionId].collateralPoints -= withdrawnCollateralPoints;

        // Decrement total system collateral points.
        totalSystemCollateralPoints -= withdrawnCollateralPoints;

        // Transfer collateral to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, collateral);

        emit Supply(positionId, collateral);
    }

    function supplyCollateral(uint256 positionId, uint256 collateral) external {
        // Get position details.
        Position memory pos = positions[positionId];

        // Check whether position exists.
        require(pos.owner != address(0), PositionDNE());

        // Calculate collateral points.
        uint256 suppliedCollateralPoints = collateral.divWad(collateralPerCollateralPoint);

        // Update total system collateral points.
        totalSystemCollateralPoints += suppliedCollateralPoints;

        // Update position's collateral points.
        positions[positionId].collateralPoints += suppliedCollateralPoints;

        // Pull wrapped native tokens as collateral
        WRAPPED_NATIVE_TOKEN.transferFrom(msg.sender, address(this), collateral);

        emit Supply(positionId, collateral);
    }

    // =============================================================//
    //                            REDEEM                            //
    // =============================================================//

    function redeem(uint256 amount, address recipient) external {
        // Get the native token price.
        uint256 priceWAD = _getPriceWAD();

        // Calculate fees amount.
        uint256 fees = _getFeeRateWAD(amount).mulWadUp(amount);

        // Calculate native token redemption value.
        uint256 nativeTokenValue = (amount - fees).divWad(priceWAD);

        // Transfer $MAD fees to the system.
        _transfer(msg.sender, address(this), fees);

        // Burn redeemed $MAD.
        _burn(msg.sender, (amount - fees));

        // Transfer native tokens to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, nativeTokenValue);

        emit Redeem(msg.sender, amount, nativeTokenValue);
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
        require(pos.owner != address(0), PositionDNE());

        // Calculate LTV.
        uint256 debtPerPoint = debtPerDebtPoint;
        uint256 collateralPerPoint = collateralPerCollateralPoint;

        uint256 posDebt = debtPerPoint.mulWad(pos.debtPoints);
        uint256 posCollateral = collateralPerPoint.mulWad(pos.collateralPoints);

        // Check whether LTV is above 90%.
        require(posDebt.divWad(posCollateral.mulWad(priceWAD)) >= 0.9 ether, LTVInBounds());

        // Calculate liquidation reward in collateral.
        uint256 liquidationReward = posCollateral.mulWad(BASE_FEE_RATE_BPS);

        // Cover as much debt as possible from insurance reserve.
        uint256 systemBalance = balanceOf(address(this));

        uint256 debtToBurn = posDebt;
        uint256 collateralToRelease = posCollateral - liquidationReward;

        if (systemBalance > 0) {
            // Burn as much debt as possible from insurance reserve.
            uint256 burnAmount = systemBalance < debtToBurn ? systemBalance : debtToBurn;
            _burn(address(this), burnAmount);

            // Compensate system with collateral.
            uint256 totalReward = (collateralToRelease).mulWad(burnAmount.divWadUp(debtToBurn));
            lifetimeRewardPerMAD += (totalReward).divWadUp(totalStaked);

            // Update remainder debt amount.
            debtToBurn -= burnAmount;

            // Update remainder collateral to release.
            collateralToRelease -= totalReward;
        }

        if (debtToBurn > 0) {
            // Distribute debt across positions.
            debtPerDebtPoint += debtToBurn.divWad(totalSystemDebtPoints);

            // Distribute collateral across positions.
            collateralPerCollateralPoint += collateralToRelease.divWad(totalSystemCollateralPoints);
        }

        // Transfer liquidation reward in collateral to recipient.
        WRAPPED_NATIVE_TOKEN.transfer(recipient, liquidationReward);

        // Delete position.
        delete positions[positionId];

        emit Liquidate(positionId, recipient, posDebt, posCollateral);
    }

    // =============================================================//
    //                            STAKE                             //
    // =============================================================//

    function stake(uint256 amount) external {
        // Update staker reward debt with rewards missed by amount being staked just now.
        rewardDebt[msg.sender] += lifetimeRewardPerMAD.mulWadUp(amount);

        // Update total staked amount.
        totalStaked += amount;

        // Update staker's stake amount.
        staked[msg.sender] += amount;

        // Transfer $MAD stake to the system.
        _transfer(msg.sender, address(this), amount);

        emit Stake(msg.sender, amount);
    }

    function unstake() external {
        // Get staker's stake amount and reward debt.
        uint256 stakeAmount = staked[msg.sender];
        uint256 debt = rewardDebt[msg.sender];

        // Calculate rewards earned by staker.
        uint256 totalRewards = lifetimeRewardPerMAD.mulWad(stakeAmount) - debt;

        // Calculate withdraw amount.
        uint256 withdrawAmount = balanceOf(address(this)).mulWad(stakeAmount).divWad(totalStaked);

        // Update total staked amount.
        totalStaked -= stakeAmount;

        // Reset staker's reward debt.
        delete rewardDebt[msg.sender];

        // Reset staker's stake amount.
        delete staked[msg.sender];

        // Transfer rewards to staker.
        WRAPPED_NATIVE_TOKEN.transfer(msg.sender, totalRewards);

        // Transfer $MAD stake to the staker.
        _transfer(address(this), msg.sender, withdrawAmount);

        emit Unstake(msg.sender, withdrawAmount);
    }

    function claimRewards() external {
        // Get staker's stake amount and reward debt.
        uint256 stakeAmount = staked[msg.sender];
        uint256 debt = rewardDebt[msg.sender];

        // Calculate rewards earned by staker.
        uint256 totalRewards = lifetimeRewardPerMAD.mulWad(stakeAmount) - debt;

        // Update staker's reward debt.
        rewardDebt[msg.sender] += totalRewards;

        // Transfer rewards to staker.
        WRAPPED_NATIVE_TOKEN.transfer(msg.sender, totalRewards);

        emit ClaimRewards(msg.sender, totalRewards);
    }

    // =============================================================//
    //                            PRICE                             //
    // =============================================================//

    function _getPriceWAD() private view returns (uint256) {
        return (PRICE_ORACLE.price() * 1 ether) / (10 ** PRICE_ORACLE.scale());
    }

    // =============================================================//
    //                         FEE RATE                             //
    // =============================================================//

    function _getFeeRateWAD(uint256 redeemAmount) private returns (uint256) {
        // Variable fee rate is calculated as `r(n) = r(n-1) * (decay ^ hoursElapsed)`.
        uint256 currentVariableRate = variableFeeRate.mulWadUp(
            uint256(int256(DECAY_RATE_SCALED).powWad(int256((block.timestamp - lastFeeUpdateTimestamp) / 1 hours)))
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
