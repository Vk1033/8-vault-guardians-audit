// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IVaultShares, IERC4626} from "../interfaces/IVaultShares.sol";
import {AaveAdapter, IPool} from "./investableUniverseAdapters/AaveAdapter.sol";
import {UniswapAdapter} from "./investableUniverseAdapters/UniswapAdapter.sol";
import {DataTypes} from "../vendor/DataTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract VaultShares is ERC4626, IVaultShares, AaveAdapter, UniswapAdapter, ReentrancyGuard {
    error VaultShares__DepositMoreThanMax(uint256 amount, uint256 max);
    error VaultShares__NotGuardian();
    error VaultShares__NotVaultGuardianContract();
    error VaultShares__AllocationNot100Percent(uint256 totalAllocation);
    error VaultShares__NotActive();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    IERC20 internal immutable i_uniswapLiquidityToken;
    IERC20 internal immutable i_aaveAToken;
    address private immutable i_guardian;
    address private immutable i_vaultGuardians;
    uint256 private immutable i_guardianAndDaoCut;
    bool private s_isActive;

    AllocationData private s_allocationData;

    uint256 private constant ALLOCATION_PRECISION = 1_000;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event UpdatedAllocation(AllocationData allocationData);
    event NoLongerActive();
    event FundsInvested();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGuardian() {
        if (msg.sender != i_guardian) {
            revert VaultShares__NotGuardian();
        }
        _;
    }

    modifier onlyVaultGuardians() {
        if (msg.sender != i_vaultGuardians) {
            revert VaultShares__NotVaultGuardianContract();
        }
        _;
    }

    modifier isActive() {
        if (!s_isActive) {
            revert VaultShares__NotActive();
        }
        _;
    }

    // slither-disable-start reentrancy-eth
    /**
     * @notice removes all supplied liquidity from Uniswap and supplied lending amount from Aave and then re-invests it back into them only if the vault is active
     */
    //d why we need to do this?, to gte value of underlying asset at that time to withdraw or redeem
    modifier divestThenInvest() {
        uint256 uniswapLiquidityTokensBalance = i_uniswapLiquidityToken.balanceOf(address(this));
        uint256 aaveAtokensBalance = i_aaveAToken.balanceOf(address(this));

        // Divest
        if (uniswapLiquidityTokensBalance > 0) {
            _uniswapDivest(IERC20(asset()), uniswapLiquidityTokensBalance);
        }
        if (aaveAtokensBalance > 0) {
            _aaveDivest(IERC20(asset()), aaveAtokensBalance);
        }

        _;

        // Reinvest
        if (s_isActive) {
            _investFunds(IERC20(asset()).balanceOf(address(this)));
        }
    }
    // slither-disable-end reentrancy-eth

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // We use a struct to avoid stack too deep errors. Thanks Solidity
    constructor(ConstructorData memory constructorData)
        ERC4626(constructorData.asset)
        ERC20(constructorData.vaultName, constructorData.vaultSymbol)
        AaveAdapter(constructorData.aavePool)
        UniswapAdapter(constructorData.uniswapRouter, constructorData.weth, constructorData.usdc)
    {
        i_guardian = constructorData.guardian;
        i_guardianAndDaoCut = constructorData.guardianAndDaoCut;
        i_vaultGuardians = constructorData.vaultGuardians;
        s_isActive = true;
        updateHoldingAllocation(constructorData.allocationData);

        // External calls
        //d check these again with orginal contracts, they are good prolly
        i_aaveAToken =
            IERC20(IPool(constructorData.aavePool).getReserveData(address(constructorData.asset)).aTokenAddress);
        i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(i_weth)));
    }

    /**
     * @notice Sets the vault as not active, which means that the vault guardian has quit
     * @notice Users will not be able to invest in this vault, however, they will be able to withdraw their deposited assets
     */
    function setNotActive() public onlyVaultGuardians isActive {
        s_isActive = false;
        emit NoLongerActive();
    }

    /**
     * @notice Allows Vault Guardians to update their allocation ratio (and thus, their strategy of investment)
     * @param tokenAllocationData The new allocation data
     */
    //d check for allocation precision, yes sums upto 1
    function updateHoldingAllocation(AllocationData memory tokenAllocationData) public onlyVaultGuardians isActive {
        uint256 totalAllocation = tokenAllocationData.holdAllocation + tokenAllocationData.uniswapAllocation
            + tokenAllocationData.aaveAllocation;
        if (totalAllocation != ALLOCATION_PRECISION) {
            revert VaultShares__AllocationNot100Percent(totalAllocation);
        }
        s_allocationData = tokenAllocationData;
        emit UpdatedAllocation(tokenAllocationData);
    }

    /**
     * @dev See {IERC4626-deposit}. Overrides the Openzeppelin implementation.
     *
     * @notice Mints shares to the DAO and the guardian as a fee
     */
    // slither-disable-start reentrancy-eth

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

        // uint256 totalShares = previewDeposit(assets);
        // uint256 fee = totalShares / i_guardianAndDaoCut; // or however you want to split
        // uint256 userShares = totalShares - 2 * fee; // net after fees

        // _deposit(_msgSender(), receiver, assets, userShares);

        // _mint(i_guardian, fee);
        // _mint(i_vaultGuardians, fee);

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        //d shouldnt Dao and guardian shares be substracted? from receiver's shares? exactly its a medium
        _mint(i_guardian, shares / i_guardianAndDaoCut);
        _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }

    /**
     * @notice Invests user deposited assets into the investable universe (hold, Uniswap, or Aave) based on the allocation data set by the vault guardian
     * @param assets The amount of assets to invest
     */
    function _investFunds(uint256 assets) private {
        uint256 uniswapAllocation = (assets * s_allocationData.uniswapAllocation) / ALLOCATION_PRECISION;
        uint256 aaveAllocation = (assets * s_allocationData.aaveAllocation) / ALLOCATION_PRECISION;

        emit FundsInvested();

        _uniswapInvest(IERC20(asset()), uniswapAllocation);
        _aaveInvest(IERC20(asset()), aaveAllocation);
    }

    // slither-disable-start reentrancy-benign
    /* 
     * @notice Unintelligently just withdraws everything, and then reinvests it all. 
     * @notice Anyone can call this and pay the gas costs to rebalance the portfolio at any time. 
     * @dev We understand that this is horrible for gas costs. 
     */
    //d, why we need to do this? +> make the allocation changged , so to rebalance
    //d, non reentrancy guard at the not not of any use
    function rebalanceFunds() public isActive divestThenInvest nonReentrant {}

    /**
     * @dev See {IERC4626-withdraw}.
     *
     * We first divest our assets so we get a good idea of how many assets we hold.
     * Then, we redeem for the user, and automatically reinvest.
     */
    //d, why divest and invest, and not only divest as is natspec? its a modifier
    //d non reentrancy guard at the not not of any use
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(IERC4626, ERC4626)
        divestThenInvest
        nonReentrant
        returns (uint256)
    {
        uint256 shares = super.withdraw(assets, receiver, owner);
        return shares;
    }

    /**
     * @dev See {IERC4626-redeem}.
     *
     * We first divest our assets so we get a good idea of how many assets we hold.
     * Then, we redeem for the user, and automatically reinvest.
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(IERC4626, ERC4626)
        divestThenInvest
        nonReentrant
        returns (uint256)
    {
        uint256 assets = super.redeem(shares, receiver, owner);
        return assets;
    }
    // slither-disable-end reentrancy-eth
    // slither-disable-end reentrancy-benign

    /*//////////////////////////////////////////////////////////////
                             VIEW AND PURE
    //////////////////////////////////////////////////////////////*/
    /**
     * @return The guardian of the vault
     */
    function getGuardian() external view returns (address) {
        return i_guardian;
    }

    /**
     * @return The ratio of the amount in vaults that goes to the vault guardians and the DAO
     */
    function getGuardianAndDaoCut() external view returns (uint256) {
        return i_guardianAndDaoCut;
    }

    /**
     * @return Gets the address of the Vault Guardians protocol
     */
    function getVaultGuardians() external view returns (address) {
        return i_vaultGuardians;
    }

    /**
     * @return A bool indicating if the vault is active (has an active vault guardian and is accepting deposits) or not
     */
    function getIsActive() external view returns (bool) {
        return s_isActive;
    }

    /**
     * @return The Aave aToken for the vault's underlying asset
     */
    function getAaveAToken() external view returns (address) {
        return address(i_aaveAToken);
    }

    /**
     * @return Uniswap's LP token
     */
    function getUniswapLiquidtyToken() external view returns (address) {
        return address(i_uniswapLiquidityToken);
    }

    /**
     * @return The allocation data set by the vault guardian
     */
    function getAllocationData() external view returns (AllocationData memory) {
        return s_allocationData;
    }
}
