//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from '../Mock/MockV3Aggregator.sol';

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;

    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        dsce = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 _amount) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(msg.sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) -
            int256(totalDscMinted);

        if (maxDscToMint < 0) {
            return;
        }

        _amount = bound(_amount, 0, uint256(maxDscToMint));

        if (_amount == 0) {
            return;
        }

        vm.startPrank(msg.sender);

        dsce.mintDsc(_amount);

        vm.stopPrank();

        timesMintIsCalled++;
    }

    function depositCollateral(
        uint256 _collateralSeed,
        uint256 _amountCollateral
    ) public {
        _amountCollateral = bound(_amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = getCollateralFromSeed(_collateralSeed);
        // dsce.depositCollateral(address (collateral), _amountCollateral);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, _amountCollateral);
        collateral.approve(address(dsce), _amountCollateral);

        dsce.depositCollateral(address(collateral), _amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function updateCollateralPrice(uint96 _newPrice) public {
        int256 newPriceInt = int256(uint256 (_newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }

    function redeemCollateral(
        uint256 _collateralSeed,
        uint256 _amountCollateral
    ) public {
        ERC20Mock collateral = getCollateralFromSeed(_collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(
            address(collateral),
            msg.sender
        );

        _amountCollateral = bound(_amountCollateral, 0, maxCollateralToRedeem);

        if (_amountCollateral == 0) {
            return;
        }

        dsce.redeemCollateral(address(collateral), _amountCollateral);
    }

    function getCollateralFromSeed(
        uint256 _collateralSeed
    ) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
