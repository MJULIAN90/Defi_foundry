// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

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

    // ****************************
    // State Variables         ****
    // ****************************
    uint256 private constant ADDITIONAL_FEED_PRESICION = 1e10;
    uint256 private constant PRESICION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRESICION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

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
        address indexed user,
        address indexed token,
        uint256 indexed amount
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
    }

    function redeemCollateralForDsc(address _tokenCollateralAddress, uint256 _amountCollateral, uint256 _amountDscToBurn) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
    }

    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral) public moreThanZero(_amountCollateral) nonReentrant{
        sCollateralDeposited[msg.sender][_tokenCollateralAddress] -= _amountCollateral;
        emit DSCEngine__CollateralRedeemed(msg.sender, _tokenCollateralAddress, _amountCollateral);

        bool sucess = IERC20(_tokenCollateralAddress).transfer(msg.sender, _amountCollateral);
        if(!sucess) {
            revert DSCEngine__TransferFailed();
        }
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
        sdscMinted[msg.sender] -= _amount;
        bool success = I_DSC.transferFrom(msg.sender, address(this), _amount);

        if(!success) {
            revert DSCEngine__TransferFailed();
        }

        I_DSC.burn(_amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate() external {}

    function getHealthFactor() external view {}

    // ********************************************
    // Private & Internal View Functions       ****
    // ********************************************

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

    function _healthFactor(address _user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(_user);

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRESICION;

        return (collateralAdjustedForThreshold * PRESICION) / totalDscMinted;
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
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            ((uint256(price) * ADDITIONAL_FEED_PRESICION) * _amount) /
            PRESICION;
    }
}
