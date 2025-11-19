// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author Julian Ruiz
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    // ****************************
    // Errors                  ****
    // ****************************

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // ****************************
    // Types                   ****
    // ****************************

    using OracleLib for AggregatorV3Interface;

    // ****************************
    // State Variables         ****
    // ****************************
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% OVERCOLLATERIZED
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // THIS MEANS A 10% BONUS

    mapping(address token => address priceFeed) private sPriceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount))
        private sCollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private sdscMinted;
    address[] private sCollateralTokens;

    DecentralizedStableCoin private immutable I_DSC;

    // ****************************
    // Events                  ****
    // ****************************

    event DSCEngine__CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event DSCEngine__CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    // ****************************
    // Modifiers               ****
    // ****************************

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (sPriceFeeds[_token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // ****************************
    // Functions               ****
    // ****************************

    constructor(
        address[] memory _tokenAdresses,
        address[] memory _priceFeedAddesses,
        address dscAddress
    ) {
        // USD Price feeds
        if (_tokenAdresses.length != _priceFeedAddesses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        uint256 tokenAdressesNumberItems = _tokenAdresses.length;

        // For example ETH / USD, BTC / USD
        for (uint256 i = 0; i < tokenAdressesNumberItems; i++) {
            sPriceFeeds[_tokenAdresses[i]] = _priceFeedAddesses[i];

            sCollateralTokens.push(_tokenAdresses[i]);
        }

        I_DSC = DecentralizedStableCoin(dscAddress);
    }

    // ****************************
    // External Functions      ****
    // ****************************

    /*
     * @params _tokenCollateralAddress The address of the token to deposit as collateral
     * @params _amountCollateral The amount of collateral to deposit
     * @params _amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    function depositCollateralAndMintDsc() external {}

    /*
     * @params tokenCollateralAddress The address of the token to deposit as collateral
     * @params amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    )
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        sCollateralDeposited[msg.sender][
            _tokenCollateralAddress
        ] += _amountCollateral;
        emit DSCEngine__CollateralDeposited(
            msg.sender,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool sucess = IERC20(_tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            _amountCollateral
        );

        // After create CustomError.
        if (!sucess) {
            revert();
        }
    }

    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
    }

    function redeemCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) public moreThanZero(_amountCollateral) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            _tokenCollateralAddress,
            _amountCollateral
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDsc(
        uint256 _amountDscToMint
    ) public moreThanZero(_amountDscToMint) nonReentrant {
        sdscMinted[msg.sender] += _amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = I_DSC.mint(msg.sender, _amountDscToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        _burnDsc(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(
        address _collateral,
        address _user,
        uint256 _debtToCover
    ) external moreThanZero(_debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            _collateral,
            _debtToCover
        );

        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;

        _redeemCollateral(
            _user,
            msg.sender,
            _collateral,
            totalCollateralToRedeem
        );

        _burnDsc(_debtToCover, _user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(_user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    // ********************************************
    // Private & Internal View Functions       ****
    // ********************************************

    function _burnDsc(
        uint256 _amountDscToBurn,
        address _onBehalfOf,
        address _dscFrom
    ) private {
        sdscMinted[_onBehalfOf] -= _amountDscToBurn;
        bool success = I_DSC.transferFrom(
            _dscFrom,
            address(this),
            _amountDscToBurn
        );

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        I_DSC.burn(_amountDscToBurn);
    }

    function _redeemCollateral(
        address _from,
        address _to,
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) private {
        sCollateralDeposited[_from][
            _tokenCollateralAddress
        ] -= _amountCollateral;
        emit DSCEngine__CollateralRedeemed(
            _from,
            _to,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool sucess = IERC20(_tokenCollateralAddress).transfer(
            _to,
            _amountCollateral
        );
        if (!sucess) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address _user
    )
        private
        view
        returns (uint256 _totalDscMinted, uint256 _collateralValueInUsd)
    {
        _totalDscMinted = sdscMinted[_user];
        _collateralValueInUsd = getAccountCollateralValue(_user);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _healthFactor(address _user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(_user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    // ********************************************
    // Public & External View Functions        ****
    // ********************************************
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(
        address _token,
        uint256 _usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            sPriceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        return
            (_usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address _user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        uint256 sCollateralTokensNumberItems = sCollateralTokens.length;

        for (uint256 i = 0; i < sCollateralTokensNumberItems; i++) {
            address token = sCollateralTokens[i];
            uint256 amount = sCollateralDeposited[_user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            sPriceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) /
            PRECISION;
    }

    function getAccountInformation(
        address _user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(_user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return sCollateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(I_DSC);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return sPriceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(
        address _user,
        address _token
    ) external view returns (uint256) {
        return sCollateralDeposited[_user][_token];
    }
}
