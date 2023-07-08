// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;
import {AccessController} from "./access/AccessController.sol";
import {IIndexSwap} from "./core/IIndexSwap.sol";
import {IOffChainIndexSwap} from "./core/IOffChainIndexSwap.sol";
import {IAssetManagerConfig} from "./registry/IAssetManagerConfig.sol";
import {IRebalancing} from "./rebalance/IRebalancing.sol";
import {IOffChainRebalance} from "./rebalance/IOffChainRebalance.sol";
import {IRebalanceAggregator} from "./rebalance/IRebalanceAggregator.sol";
import {IExchange} from "./core/IExchange.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable-4.3.2/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable-4.3.2/access/OwnableUpgradeable.sol";
import {FunctionParameters} from "./FunctionParameters.sol";
import {ErrorLibrary} from "./library/ErrorLibrary.sol";
import {ITokenRegistry} from "./registry/ITokenRegistry.sol";
import {IFeeModule} from "./fee/IFeeModule.sol";
import {IVelvetSafeModule} from "./vault/IVelvetSafeModule.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VelvetSafeModule} from "./vault/VelvetSafeModule.sol";
import {GnosisDeployer} from "contracts/library/GnosisDeployer.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable-4.3.2/security/ReentrancyGuardUpgradeable.sol";

contract IndexFactory is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
  address public indexSwapLibrary;
  address internal baseIndexSwapAddress;
  address internal baseRebalancingAddress;
  address internal baseOffChainRebalancingAddress;
  address internal baseRebalanceAggregatorAddress;
  address internal baseExchangeHandlerAddress;
  address internal baseAssetManagerConfigAddress;
  address internal feeModuleImplementationAddress;
  address internal baseOffChainIndexSwapAddress;
  address internal baseVelvetGnosisSafeModuleAddress;
  address public tokenRegistry;
  address public priceOracle;
  uint256 internal maxInvestmentAmount;
  uint256 internal minInvestmentAmount;
  bool internal indexCreationPause;
  //Gnosis Helper Contracts
  address public gnosisSingleton;
  address public gnosisFallbackLibrary;
  address public gnosisMultisendLibrary;
  address public gnosisSafeProxyFactory;

  uint256 public indexId;

  uint256 public velvetProtocolFee;

  mapping(address => uint256) internal indexSwapToId;

  struct IndexSwaplInfo {
    address indexSwap;
    address rebalancing;
    address offChainRebalancing;
    address metaAggregator;
    address owner;
    address exchangeHandler;
    address assetManagerConfig;
    address feeModule;
    address offChainIndexSwap;
    address vaultAddress;
    address gnosisModule;
  }

  IndexSwaplInfo[] public IndexSwapInfolList;
  //Events
  event IndexInfo(uint256 time, IndexSwaplInfo indexData, uint256 indexed indexId, address _owner);
  event IndexCreationState(uint256 time, bool state);
  event UpgradeIndexSwap(uint256 time, address newImplementation);
  event UpgradeExchange(uint256 time, address newImplementation);
  event UpgradeAssetManagerConfig(uint256 time, address newImplementation);
  event UpgradeOffchainRebalance(uint256 time, address newImplementation);
  event UpgradeOffChainIndex(uint256 time, address newImplementation);
  event UpgradeFeeModule(uint256 time, address newImplementation);
  event UpgradeRebalanceAggregator(uint256 time, address newImplementation);
  event UpgradeRebalance(uint256 time, address newImplementation);
  event UpdateGnosisAddresses(
    uint256 time,
    address newGnosisSingleton,
    address newGnosisFallbackLibrary,
    address newGnosisMultisendLibrary,
    address newGnosisSafeProxyFactory
  );

  /**
   * @notice This function is used to initialise the IndexFactory while deployment
   */
  function initialize(FunctionParameters.IndexFactoryInitData memory initData) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init();
    if (
      initData._indexSwapLibrary == address(0) ||
      initData._baseExchangeHandlerAddress == address(0) ||
      initData._baseOffChainRebalancingAddress == address(0) ||
      initData._baseIndexSwapAddress == address(0) ||
      initData._baseRebalancingAddres == address(0) ||
      initData._baseRebalanceAggregatorAddress == address(0) ||
      initData._baseAssetManagerConfigAddress == address(0) ||
      initData._baseOffChainIndexSwapAddress == address(0) ||
      initData._feeModuleImplementationAddress == address(0) ||
      initData._baseVelvetGnosisSafeModuleAddress == address(0) ||
      initData._gnosisSingleton == address(0) ||
      initData._gnosisFallbackLibrary == address(0) ||
      initData._gnosisMultisendLibrary == address(0) ||
      initData._gnosisSafeProxyFactory == address(0)
    ) {
      revert ErrorLibrary.InvalidAddress();
    }
    indexSwapLibrary = initData._indexSwapLibrary;
    priceOracle = initData._priceOracle;
    _setBaseIndexSwapAddress(initData._baseIndexSwapAddress);
    _setBaseRebalancingAddress(initData._baseRebalancingAddres);
    _setBaseOffChainRebalancingAddress(initData._baseOffChainRebalancingAddress);
    _setRebalanceAggregatorAddress(initData._baseRebalanceAggregatorAddress);
    _setBaseExchangeHandlerAddress(initData._baseExchangeHandlerAddress);
    _setBaseAssetManagerConfigAddress(initData._baseAssetManagerConfigAddress);
    _setBaseOffChainIndexSwapAddress(initData._baseOffChainIndexSwapAddress);
    _setFeeModuleImplementationAddress(initData._feeModuleImplementationAddress);
    baseVelvetGnosisSafeModuleAddress = initData._baseVelvetGnosisSafeModuleAddress;
    tokenRegistry = initData._tokenRegistry;
    maxInvestmentAmount = initData._maxInvestmentAmount;
    minInvestmentAmount = initData._minInvestmentAmount;
    velvetProtocolFee = initData._velvetProtocolFee;
    gnosisSingleton = initData._gnosisSingleton;
    gnosisFallbackLibrary = initData._gnosisFallbackLibrary;
    gnosisMultisendLibrary = initData._gnosisMultisendLibrary;
    gnosisSafeProxyFactory = initData._gnosisSafeProxyFactory;
    indexId = 0;
    indexCreationPause = false;
  }

  /**
   * @notice This function enables to create a new non custodial portfolio
   * @param initData Accepts the input data from the user
   */
  function createIndexNonCustodial(
    FunctionParameters.IndexCreationInitData memory initData
  ) public virtual nonReentrant {
    address[] memory _owner = new address[](1);
    _owner[0] = address(0x0000000000000000000000000000000000000000);
    _createIndex(initData, false, _owner, 1);
  }

  /**
   * @notice This function enables to create a new custodial portfolio
   * @param initData Accepts the input data from the user
   * @param _owners Array list of owners for gnosis safe
   * @param _threshold Threshold for the gnosis safe(min number of transaction required)
   */
  function createIndexCustodial(
    FunctionParameters.IndexCreationInitData memory initData,
    address[] memory _owners,
    uint256 _threshold
  ) public virtual nonReentrant {
    if (_owners.length == 0) {
      revert ErrorLibrary.NoOwnerPassed();
    }
    if (_threshold > _owners.length || _threshold == 0) {
      revert ErrorLibrary.InvalidThresholdLength();
    }
    _createIndex(initData, true, _owners, _threshold);
  }

  /**
   * @notice This internal function enables to create a new portfolio according to given inputs
   */
  function _createIndex(
    FunctionParameters.IndexCreationInitData memory initData,
    bool _custodial,
    address[] memory _owner,
    uint256 _threshold
  ) internal virtual {
    if (initData.minIndexInvestmentAmount < minInvestmentAmount) {
      revert ErrorLibrary.InvalidMinInvestmentAmount();
    }
    if (initData.maxIndexInvestmentAmount > maxInvestmentAmount) {
      revert ErrorLibrary.InvalidMaxInvestmentAmount();
    }
    if (indexCreationPause) {
      revert ErrorLibrary.indexCreationIsPause();
    }
    if (initData._assetManagerTreasury == address(0)) {
      revert ErrorLibrary.InvalidAddress();
    }
    if (ITokenRegistry(tokenRegistry).getProtocolState() == true) {
      revert ErrorLibrary.ProtocolIsPaused();
    }

    //Exchange Handler
    ERC1967Proxy _exchangeHandler = new ERC1967Proxy(baseExchangeHandlerAddress, bytes(""));

    // Access Controller
    AccessController accessController = new AccessController();

    ERC1967Proxy _assetManagerConfig = new ERC1967Proxy(
      baseAssetManagerConfigAddress,
      abi.encodeWithSelector(
        IAssetManagerConfig.init.selector,
        FunctionParameters.AssetManagerConfigInitData({
          _managementFee: initData._managementFee,
          _performanceFee: initData._performanceFee,
          _entryFee: initData._entryFee,
          _exitFee: initData._exitFee,
          _minInvestmentAmount: initData.minIndexInvestmentAmount,
          _maxInvestmentAmount: initData.maxIndexInvestmentAmount,
          _tokenRegistry: tokenRegistry,
          _accessController: address(accessController),
          _assetManagerTreasury: initData._assetManagerTreasury,
          _whitelistedTokens: initData._whitelistedTokens,
          _publicPortfolio: initData._public,
          _transferable: initData._transferable,
          _transferableToPublic: initData._transferableToPublic,
          _whitelistTokens: initData._whitelistTokens
        })
      )
    );

    ERC1967Proxy _feeModule = new ERC1967Proxy(feeModuleImplementationAddress, bytes(""));
    // Vault creation
    address vaultAddress;
    address module;
    if (!_custodial) {
      _owner[0] = address(_exchangeHandler);
      _threshold = 1;
    }

    (vaultAddress, module) = GnosisDeployer.deployGnosisSafeAndModule(
      gnosisSingleton,
      gnosisSafeProxyFactory,
      gnosisMultisendLibrary,
      gnosisFallbackLibrary,
      baseVelvetGnosisSafeModuleAddress,
      _owner,
      _threshold
    );
    IVelvetSafeModule(address(module)).setUp(
      abi.encode(vaultAddress, address(_exchangeHandler), address(gnosisMultisendLibrary))
    );

    ERC1967Proxy indexSwap = new ERC1967Proxy(
      baseIndexSwapAddress,
      abi.encodeWithSelector(
        IIndexSwap.init.selector,
        FunctionParameters.IndexSwapInitData({
          _name: initData.name,
          _symbol: initData.symbol,
          _vault: vaultAddress,
          _module: module,
          _oracle: priceOracle,
          _accessController: address(accessController),
          _tokenRegistry: tokenRegistry,
          _exchange: address(_exchangeHandler),
          _iAssetManagerConfig: address(_assetManagerConfig),
          _feeModule: address(_feeModule)
        })
      )
    );

    ERC1967Proxy offChainIndexSwap = new ERC1967Proxy(
      baseOffChainIndexSwapAddress,
      abi.encodeWithSelector(IOffChainIndexSwap.init.selector, address(indexSwap))
    );

    // Index Manager
    IExchange(address(_exchangeHandler)).init(address(accessController), module, priceOracle, tokenRegistry);
    ERC1967Proxy rebalancing = new ERC1967Proxy(
      baseRebalancingAddress,
      abi.encodeWithSelector(IRebalancing.init.selector, IIndexSwap(address(indexSwap)), address(accessController))
    );

    ERC1967Proxy rebalanceAggregator = new ERC1967Proxy(
      baseRebalanceAggregatorAddress,
      abi.encodeWithSelector(
        IRebalanceAggregator.init.selector,
        address(indexSwap),
        address(accessController),
        address(_exchangeHandler),
        tokenRegistry,
        address(_assetManagerConfig),
        vaultAddress
      )
    );

    ERC1967Proxy offChainRebalancing = new ERC1967Proxy(
      baseOffChainRebalancingAddress,
      abi.encodeWithSelector(
        IOffChainRebalance.init.selector,
        IIndexSwap(address(indexSwap)),
        address(accessController),
        address(_exchangeHandler),
        tokenRegistry,
        address(_assetManagerConfig),
        vaultAddress,
        address(rebalanceAggregator)
      )
    );

    IndexSwapInfolList.push(
      IndexSwaplInfo(
        address(indexSwap),
        address(rebalancing),
        address(offChainRebalancing),
        address(rebalanceAggregator),
        msg.sender,
        address(_exchangeHandler),
        address(_assetManagerConfig),
        address(_feeModule),
        address(offChainIndexSwap),
        address(vaultAddress),
        address(module)
      )
    );

    accessController.setUpRoles(
      FunctionParameters.AccessSetup({
        _exchangeHandler: address(_exchangeHandler),
        _index: address(indexSwap),
        _tokenRegistry: tokenRegistry,
        _portfolioCreator: msg.sender,
        _rebalancing: address(rebalancing),
        _offChainRebalancing: address(offChainRebalancing),
        _rebalanceAggregator: address(rebalanceAggregator),
        _feeModule: address(_feeModule),
        _offChainIndexSwap: address(offChainIndexSwap)
      })
    );

    IFeeModule(address(_feeModule)).init(
      address(indexSwap),
      address(_assetManagerConfig),
      tokenRegistry,
      address(accessController)
    );

    emit IndexInfo(block.timestamp, IndexSwapInfolList[indexId], indexId, msg.sender);
    indexId = indexId + 1;
  }

  /**
   * @notice This function returns the IndexSwap address at the given index id
   */
  function getIndexList(uint256 indexfundId) external view virtual returns (address) {
    return address(IndexSwapInfolList[indexfundId].indexSwap);
  }

  /**
   * @notice This function is used to upgrade the IndexSwap contract
   */
  function upgradeIndexSwap(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setBaseIndexSwapAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeIndexSwap(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the Exchange contract
   */
  function upgradeExchange(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setBaseExchangeHandlerAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeExchange(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the AssetManagerConfig contract
   */
  function upgradeAssetManagerConfig(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setBaseAssetManagerConfigAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeAssetManagerConfig(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the OffChainRebalance contract
   */
  function upgradeOffchainRebalance(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setBaseOffChainRebalancingAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeOffchainRebalance(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the OffChainIndexSwap contract
   */
  function upgradeOffChainIndex(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setBaseOffChainIndexSwapAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeOffChainIndex(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the FeeModule contract
   */
  function upgradeFeeModule(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setFeeModuleImplementationAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeFeeModule(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the Rebalance Aggregator contract
   */
  function upgradeRebalanceAggregator(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setRebalanceAggregatorAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeRebalanceAggregator(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is used to upgrade the Rebalance contract
   */
  function upgradeRebalance(address[] calldata _proxy, address _newImpl) external virtual onlyOwner {
    _setBaseRebalancingAddress(_newImpl);
    _upgrade(_proxy, _newImpl);
    emit UpgradeRebalance(block.timestamp, _newImpl);
  }

  /**
   * @notice This function is the base UUPS upgrade function used to make all the upgrades happen
   */
  function _upgrade(address[] calldata _proxy, address _newImpl) internal virtual onlyOwner {
    if (ITokenRegistry(tokenRegistry).getProtocolState() == false) {
      revert ErrorLibrary.ProtocolNotPaused();
    }
    if (_newImpl == address(0)) {
      revert ErrorLibrary.InvalidAddress();
    }
    for (uint256 i = 0; i < _proxy.length; i++) {
      UUPSUpgradeable(_proxy[i]).upgradeTo(_newImpl);
    }
  }

  /**
   * @notice This function allows us to pause or unpause the index creation state
   */
  function setIndexCreationState(bool _state) public virtual onlyOwner {
    indexCreationPause = _state;
    emit IndexCreationState(block.timestamp, _state);
  }

  /**
   * @notice This function is used to set the base indexswap address
   */
  function _setBaseIndexSwapAddress(address _indexSwap) internal {
    baseIndexSwapAddress = _indexSwap;
  }

  /**
   * @notice This function is used to set the base exchange handler address
   */
  function _setBaseExchangeHandlerAddress(address _exchange) internal {
    baseExchangeHandlerAddress = _exchange;
  }

  /**
   * @notice This function is used to set the base asset manager config address
   */
  function _setBaseAssetManagerConfigAddress(address _config) internal {
    baseAssetManagerConfigAddress = _config;
  }

  /**
   * @notice This function is used to set the base offchain-rebalance address
   */
  function _setBaseOffChainRebalancingAddress(address _offchainRebalance) internal {
    baseOffChainRebalancingAddress = _offchainRebalance;
  }

  /**
   * @notice This function is used to set the base offchain-indexswap address
   */
  function _setBaseOffChainIndexSwapAddress(address _offchainIndexSwap) internal {
    baseOffChainIndexSwapAddress = _offchainIndexSwap;
  }

  /**
   * @notice This function is used to set the fee module implementation address
   */
  function _setFeeModuleImplementationAddress(address _feeModule) internal {
    feeModuleImplementationAddress = _feeModule;
  }

  /**
   * @notice This function is used to set the base rebalance aggregator address
   */
  function _setRebalanceAggregatorAddress(address _rebalanceAggregator) internal {
    baseRebalanceAggregatorAddress = _rebalanceAggregator;
  }

  /**
   * @notice This function is used to set the base rebalancing address
   */
  function _setBaseRebalancingAddress(address _rebalance) internal {
    baseRebalancingAddress = _rebalance;
  }

  /**
   * @notice This function allows us to update gnosis deployment addresses
   * @param _newGnosisSingleton New address of GnosisSingleton
   * @param _newGnosisFallbackLibrary New address of GnosisFallbackLibrary
   * @param _newGnosisMultisendLibrary New address of GnosisMultisendLibrary
   * @param _newGnosisSafeProxyFactory New address of GnosisSafeProxyFactory
   */
  function updateGnosisAddresses(
    address _newGnosisSingleton,
    address _newGnosisFallbackLibrary,
    address _newGnosisMultisendLibrary,
    address _newGnosisSafeProxyFactory
  ) external virtual onlyOwner {
    gnosisSingleton = _newGnosisSingleton;
    gnosisFallbackLibrary = _newGnosisFallbackLibrary;
    gnosisMultisendLibrary = _newGnosisMultisendLibrary;
    gnosisSafeProxyFactory = _newGnosisSafeProxyFactory;

    emit UpdateGnosisAddresses(
      block.timestamp,
      _newGnosisSingleton,
      _newGnosisFallbackLibrary,
      _newGnosisMultisendLibrary,
      _newGnosisSafeProxyFactory
    );
  }

  /**
   * @notice Authorizes upgrade for this contract
   * @param newImplementation Address of the new implementation
   */
  function _authorizeUpgrade(address newImplementation) internal virtual override onlyOwner {}
}
