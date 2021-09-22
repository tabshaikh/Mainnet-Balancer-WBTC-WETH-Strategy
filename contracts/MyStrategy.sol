// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IBalancerPool} from "../interfaces/balancer/IBalancerPool.sol";
import {IMerkleRedeem} from "../interfaces/balancer/IMerkleRedeem.sol";
import "../interfaces/balancer/IAsset.sol";
import "../interfaces/erc20/IERC20.sol";

import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public lpComponent; // Token we provide liquidity with
    address public reward; // Token we farm and swap to want / lpComponent

    address public constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // Balancer Vault address
    bytes32 public constant poolId =
        0xa6f548df93de924d73be7d25dc02554c6bd66db500020000000000000000000e; // Pool Id of WBTC/WETH Balancer Pool
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    address public constant SUSHISWAP_ROUTER =
        0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506; // SushiSwap router
    address public constant POOL = 0xA6F548DF93de924d73be7D25dC02554c6bD66dB5; // WBTC/WETH Balancer Pool address
    IBalancerPool public bpt = IBalancerPool(POOL); // WBTC/WETH Balancer Pool

    uint256 public slippage;
    uint256 public constant MAX_BPS = 10000;
    address public REDEEM = 0x6d19b2bF3A36A61530909Ae65445a906D98A2Fa8; // Merkle Redeem contract address on mainnet

    // Used to signal to the Badger Tree that rewards where sent to it
    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );
        /// @dev Add config here
        want = _wantConfig[0];
        lpComponent = _wantConfig[1];
        reward = _wantConfig[2];

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        slippage = 25; // 0.5% slippage allowance

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(VAULT, type(uint256).max);
        IERC20Upgradeable(want).safeApprove(POOL, type(uint256).max);
        IERC20Upgradeable(WETH).safeApprove(POOL, type(uint256).max);
        IERC20Upgradeable(reward).safeApprove(
            SUSHISWAP_ROUTER,
            type(uint256).max
        );
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "Mainnet-Balancer-WBTC-WETH-Strategy";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return bpt.balanceOf(address(this));
    }

    /// @dev Balance of lpcomponent component
    function balanceOfLP() public view returns (uint256) {
        return IERC20Upgradeable(lpComponent).balanceOf(address(this));
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        // Checks balance of want token (WBTC)
        // returns true if balance of want > 0 as we have wbtc to deposit into the strat
        return balanceOfWant() > 0;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[1] = lpComponent;
        protectedTokens[2] = reward;
        return protectedTokens;
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(want);
        assets[1] = IAsset(WETH);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = _amount;

        bytes memory userData = abi.encode(
            uint256(IVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT),
            amounts
        );

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest(
            assets,
            amounts,
            userData,
            false
        );

        IVault(VAULT).joinPool(poolId, address(this), address(this), request);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(want);
        assets[1] = IAsset(WETH);

        uint256[] memory minAmountsOut = new uint256[](2); // minAmountsOut for respective assets

        uint256 exitTokenIndex = 0; // As wbtc is the token we want to exit with therefore exitTokenIndex = 0

        bytes memory userData = abi.encode(
            uint256(IVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT),
            balanceOfLP(),
            exitTokenIndex
        );

        IVault.ExitPoolRequest memory exit_request = IVault.ExitPoolRequest(
            assets,
            minAmountsOut,
            userData,
            false
        );

        IVault(VAULT).exitPool(
            poolId,
            address(this),
            payable(address(this)),
            exit_request
        );
    }

    /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(want);
        assets[1] = IAsset(WETH);

        uint256[] memory minAmountsOut = new uint256[](2); // minAmountsOut for respective assets
        minAmountsOut[0] = _amount.mul(MAX_BPS.sub(slippage)).div(MAX_BPS);

        bytes memory userData = abi.encode(
            IVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT,
            minAmountsOut,
            balanceOfLP()
        );

        IVault.ExitPoolRequest memory exit_request = IVault.ExitPoolRequest(
            assets,
            minAmountsOut,
            userData,
            false
        );

        IVault(VAULT).exitPool(
            poolId,
            address(this),
            payable(address(this)),
            exit_request
        );

        return _amount;
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest(IMerkleRedeem.Claim[] memory claims)
        external
        whenNotPaused
        returns (uint256 harvested)
    {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // Write your code here

        // Claim rewards
        IMerkleRedeem(REDEEM).claimWeeks(address(this), claims);

        // Swap BAL token for wBTC through path: BAL -> WETH -> wBTC
        uint256 _rewardAmount = IERC20Upgradeable(reward).balanceOf(
            address(this)
        );
        address[] memory path = new address[](3);
        path[0] = reward;
        path[1] = WETH;
        path[2] = want;
        IUniswapRouterV2(SUSHISWAP_ROUTER).swapExactTokensForTokens(
            _rewardAmount,
            0,
            path,
            address(this),
            now
        );

        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(
            _before
        );

        /// @notice Keep this in so you get paid!
        (
            uint256 governancePerformanceFee,
            uint256 strategistPerformanceFee
        ) = _processRewardsFees(earned, reward);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        /// @dev Harvest must return the amount of want increased
        return earned;
    }

    // Alternative Harvest with Price received from harvester, used to avoid exessive front-running
    function harvest(uint256 price)
        external
        whenNotPaused
        returns (uint256 harvested)
    {}

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();
        uint256 balanceOfWant = IERC20Upgradeable(want).balanceOf(
            address(this)
        );
        if (balanceOfWant > 0) {
            _deposit(balanceOfWant);
        }
    }

    /// @notice sets slippage tolerance for liquidity provision in terms of BPS ie.
    /// @notice minSlippage = 0
    /// @notice maxSlippage = 10_000
    function setSlippageTolerance(uint256 _s) external whenNotPaused {
        _onlyGovernanceOrStrategist();
        require(_s <= 10_000, "slippage out of bounds");
        slippage = _s;
    }

    /// ===== Internal Helper Functions =====

    /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
    function _processRewardsFees(uint256 _amount, address _token)
        internal
        returns (uint256 governanceRewardsFee, uint256 strategistRewardsFee)
    {
        governanceRewardsFee = _processFee(
            _token,
            _amount,
            performanceFeeGovernance,
            IController(controller).rewards()
        );

        strategistRewardsFee = _processFee(
            _token,
            _amount,
            performanceFeeStrategist,
            strategist
        );
    }
}
