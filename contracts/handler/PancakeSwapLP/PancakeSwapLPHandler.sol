// SPDX-License-Identifier: MIT

// PancakeSwap Official Docs: https://docs.pancakeswap.finance/
// PancakeSwap GitHub: https://github.com/pancakeswap

/**
 * @title Handler for the PancakeSwap's LP protocol
 * @author Velvet.Capital
 * @notice This contract is used to add and remove liquidity
 *      to/from the PancakeSwap protocol.
 * @dev This contract includes functionalities:
 *      1. Add liquidity to the PancakeSwap protocol
 *      2. Remove liquidity from the PancakeSwap protocol
 *      3. Get underlying asset address
 *      4. Get protocol token balance
 *      5. Get underlying asset balance
 */

pragma solidity 0.8.16;

import {TransferHelper} from "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable-4.3.2/utils/math/SafeMathUpgradeable.sol";

import {LPInterface} from "../interfaces/LPInterface.sol";
import {RouterInterface} from "../interfaces/RouterInterface.sol";
import {FactoryInterface} from "../interfaces/FactoryInterface.sol";
import {IMasterChef} from "./interfaces/IMasterChef.sol";
import {IMainStaking} from "./interfaces/IMainStaking.sol";
import {Babylonian} from "@uniswap/lib/contracts/libraries/Babylonian.sol";
import {IPriceOracle} from "../../oracle/IPriceOracle.sol";
import {IHandler} from "../IHandler.sol";
import {SlippageControl} from "../SlippageControl.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {ErrorLibrary} from "./../../library/ErrorLibrary.sol";
import {FunctionParameters} from "../../FunctionParameters.sol";
import {UniswapV2LPHandler} from "../AbstractLPHandler.sol";

contract PancakeSwapLPHandler is IHandler, SlippageControl, UniswapV2LPHandler {
  using SafeMathUpgradeable for uint256;

  IPriceOracle public _oracle;

  mapping(address => uint256) public pid;

  address public constant routerAddress = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
  address public constant masterChefAddress = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;
  RouterInterface public router = RouterInterface(routerAddress);
  IMasterChef public chefRouter = IMasterChef(masterChefAddress);
  uint256 public constant divisor_int = 10_000;
  address public constant MAIN_STAKING = 0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652;

  event Deposit(uint256 time, address indexed user, address indexed token, uint256[] amounts, address indexed to);
  event Redeem(
    uint256 time,
    address indexed user,
    address indexed token,
    uint256 amount,
    address indexed to,
    bool isWETH
  );

  constructor(address _priceOracle) {
    require(_priceOracle != address(0), "Oracle having zero address");
    _oracle = IPriceOracle(_priceOracle);
  }

  /**
   * @notice This function adds liquidity to the PancakeSwap protocol
   * @param _lpAsset Address of the protocol asset to be deposited
   * @param _amount Amount that is to be deposited
   * @param _lpSlippage LP slippage value passed to the function
   * @param _to Address that would receive the cTokens in return
   */
  function deposit(
    address _lpAsset,
    uint256[] memory _amount,
    uint256 _lpSlippage,
    address _to,
    address user
  ) public payable override {
    address[] memory t = getUnderlying(_lpAsset);
    uint p1 = _oracle.getPriceTokenUSD18Decimals(t[0], 1000000000000000000);
    uint p2 = _oracle.getPriceTokenUSD18Decimals(t[1], 1000000000000000000);
    _deposit(_lpAsset, _amount, _lpSlippage, _to, address(router), user, p1, p2);
    emit Deposit(block.timestamp, msg.sender, _lpAsset, _amount, _to);
  }

  /**
   * @notice This function remove liquidity from the PancakeSwap protocol
   */
  function redeem(FunctionParameters.RedeemData calldata inputData) public override {
    address[] memory t = getUnderlying(inputData._yieldAsset);
    uint p1 = _oracle.getPriceTokenUSD18Decimals(t[0], 1000000000000000000);
    uint p2 = _oracle.getPriceTokenUSD18Decimals(t[1], 1000000000000000000);
    _redeem(inputData, routerAddress, p1, p2);
    emit Redeem(block.timestamp, msg.sender, inputData._yieldAsset, inputData._amount, inputData._to, inputData.isWETH);
  }

  /**
   * @notice This function returns address of the underlying asset
   * @param _lpToken Address of the protocol token whose underlying asset is needed
   * @return underlying Address of the underlying asset
   */
  function getUnderlying(address _lpToken) public view override returns (address[] memory) {
    return _getUnderlyingTokens(_lpToken);
  }

  /**
   * @notice This function returns the protocol token balance of the passed address
   * @param _tokenHolder Address whose balance is to be retrieved
   * @param t Address of the protocol token
   * @return tokenBalance t token balance of the holder
   */
  function getTokenBalance(address _tokenHolder, address t) public view override returns (uint256 tokenBalance) {
    return _getTokenBalance(_tokenHolder, t);
  }

  /**
   * @notice This function returns the underlying asset balance of the passed address
   * @param _tokenHolder Address whose balance is to be retrieved
   * @param t Address of the protocol token
   * @return tokenBalance t token's underlying asset balance of the holder
   */
  function getUnderlyingBalance(address _tokenHolder, address t) public view override returns (uint256[] memory) {
    return _getUnderlyingBalance(_tokenHolder, t);
  }

  /**
   * @notice This function returns the USD value of the LP asset using Fair LP Price model
   * @param _tokenHolder Address whose balance is to be retrieved
   * @param t Address of the protocol token
   * @return finalLB value of the lp asset t
   */
  function getFairLpPrice(address _tokenHolder, address t) public view returns (uint) {
    uint lB = _calculatePrice(t, address(_oracle));
    uint256 balance = _getTokenBalance(_tokenHolder, t);
    uint finalLB = lB.mul(balance).div(10 ** 18);
    return finalLB;
  }

  /**
   * @notice This function allows to map token addresses to their protocol's pid value
   */
  function pidMap(address[] memory _lpTokens, uint256[] memory _pid) external onlyOwner {
    if (_lpTokens.length != _pid.length) {
      revert ErrorLibrary.InvalidLength();
    }
    for (uint256 i = 0; i < _lpTokens.length; i++) {
      pid[_lpTokens[i]] = _pid[i];
    }
  }

  /**
   * @notice This function allows to remove entries from the pid map
   */
  function removePidMap(address[] memory _lpTokens, uint256[] memory _pid) external onlyOwner {
    if (_lpTokens.length != _pid.length) {
      revert ErrorLibrary.InvalidLength();
    }
    for (uint256 i = 0; i < _lpTokens.length; i++) {
      if (pid[_lpTokens[i]] != _pid[i]) {
        revert ErrorLibrary.InvalidPID();
      }
      delete (pid[_lpTokens[i]]);
    }
  }

  function encodeData(address t, uint256 _amount) public view returns (bytes memory) {}

  function getRouterAddress() public pure returns (address) {}

  function getClaimTokenCalldata(address _token, address) public view returns (bytes memory, address) {}

  receive() external payable {}
}
