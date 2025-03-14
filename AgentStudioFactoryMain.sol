// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IPositionManager {
    struct FlaunchParams {
        string name;
        string symbol;
        string tokenUri;
        uint256 initialTokenFairLaunch;
        uint256 premineAmount;
        address creator;
        uint24 creatorFeeAllocation;
        uint256 flaunchAt;
        bytes initialPriceParams;
        bytes feeCalculatorParams;
    }

    function balances(address _recipient) external view returns (uint256 _amount);
}

interface ITreasuryManagerFactory {
    function deployManager(address _managerImplementation) external returns (address payable manager_);
}

interface IPremineZap {
    function calculateFee(
        uint256 _premineAmount,
        uint256 _slippage,
        bytes memory _initialPriceParams
    ) external view returns (uint256 ethRequired_);
    
    function flaunch(
        IPositionManager.FlaunchParams calldata params
    ) external payable returns (address memecoin_, uint256 ethSpent_);

    function positionManager() external view returns (IPositionManager);
    function flaunchContract() external view returns (IFlaunch);
}

interface IFlaunch {
    function tokenId(address _memecoin) external view returns (uint256);
    function approve(address to, uint256 tokenId) external payable;
}

interface ITreasuryManager {
    function rescue(uint256 tokenId, address recipient) external;
}

interface IRevenueManager {
    struct InitParams {
        address payable creator;
        address payable protocolRecipient;
        uint protocolFee;
    }

    function initialize(uint256 _tokenId, address _owner, bytes calldata _data) external;
    function creator() external view returns (address payable);
    function protocolRecipient() external view returns (address payable);
    function protocolFee() external view returns (uint256);
    function tokenId() external view returns (uint256);
    function setCreator(address payable _creator) external;
    function claim() external returns (uint256 creatorAmount_, uint256 protocolAmount_);
}

contract AgentStudioFactory is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    IPremineZap public premineZap;
    ITreasuryManagerFactory public treasuryFactory;
    address public revenueManagerImplementation;
    address public platformFeeReceiver;

    uint256 public platformFeeBps;

    // Tracking mappings
    mapping(address => address[]) public creatorToManagers;
    mapping(address => address) public memecoinToManager;
    mapping(address => address) public managerToMemecoin;
    mapping(address => bool) public isRegisteredManager;

    error NotCreator(address sender, address expectedCreator);
    error InvalidManager(address manager, string reason);
    error InvalidAddress(address invalidAddress, string context);
    error ImplementationNotSet(string details);
    error NFTTransferFailed(address from, address to, uint256 tokenId);
    error RefundFailed(uint256 amount, address recipient);
    error ApprovalFailed(address owner, address spender, uint256 tokenId);
    error InitializationFailed(address manager, string reason);
    error NotRegisteredManager(address manager);
    error InvalidRecipient(address recipient);
    error InvalidAmount(uint256 amount, uint256 available);
    error FeeTooHigh(uint256 fee);
    error TransferFailed(address token, address recipient, uint256 amount);
    

    event ManagerDeployed(
        address indexed creator,
        address indexed manager,
        address indexed memecoin,
        uint256 tokenId
    );
    event RevenueManagerImplementationUpdated(
        address indexed oldImplementation,
        address indexed newImplementation
    );
    event PlatformFeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event PremineZapUpdated(address indexed oldZap, address indexed newZap);
    event NFTRecovered(address indexed nftContract, uint256 indexed tokenId, address indexed to);
    event AssetRecovered(address indexed token, address indexed recipient, uint256 amount);

    constructor(
        address _premineZap,
        address _treasuryFactory,
        address _platformFeeReceiver,
        uint256 _initialFeeBps
    ) {
        if (_initialFeeBps > 10000) revert FeeTooHigh(_initialFeeBps);
        
        premineZap = IPremineZap(_premineZap);
        treasuryFactory = ITreasuryManagerFactory(_treasuryFactory);
        platformFeeReceiver = _platformFeeReceiver;
        platformFeeBps = _initialFeeBps;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
    }

    // User Functions
    function deployAndFlaunch(
        IPositionManager.FlaunchParams calldata flaunchParams
    ) external payable nonReentrant returns (address manager, address memecoin) {
        if (revenueManagerImplementation == address(0)) revert ImplementationNotSet("Revenue manager implementation address not configured");
        if (flaunchParams.creator == address(0)) revert InvalidAddress(flaunchParams.creator, "Creator address cannot be zero");
        uint256 startBalance = address(this).balance;

        // Store original creator
        address originalCreator = flaunchParams.creator;
        
        // Modify flaunchParams to set creator as the factory
        IPositionManager.FlaunchParams memory modifiedParams = flaunchParams;
        modifiedParams.creator = address(this);

        // Flaunch with original creator (user). The `ethSpent` is only allocated when we
        // premine, otherwise the fee may not be included. For this reason, we calculate the
        // balance based on balance change.
        (address _memecoin,) = premineZap.flaunch{value: msg.value}(modifiedParams);

        memecoin = _memecoin;

        // Get Flaunch contract and tokenId
        IFlaunch flaunch = premineZap.flaunchContract();
        uint256 tokenId = flaunch.tokenId(memecoin);

        // Deploy manager 
        address payable revenueManager = treasuryFactory.deployManager(revenueManagerImplementation);

        // Approve the revenue manager to use our tokenId
        flaunch.approve{value: 0}(revenueManager, tokenId);

        // Initialize manager
        try IRevenueManager(revenueManager).initialize(
            tokenId,
            address(this),
            abi.encode(IRevenueManager.InitParams({
                creator: payable(originalCreator),
                protocolRecipient: payable(platformFeeReceiver),
                protocolFee: platformFeeBps
            }))
        ) {
            // Update tracking relationships
            isRegisteredManager[revenueManager] = true;
            creatorToManagers[originalCreator].push(revenueManager);
            memecoinToManager[memecoin] = revenueManager;
            managerToMemecoin[revenueManager] = memecoin;

            // Refund excess ETH if any
            uint256 ethUsed = startBalance + msg.value - address(this).balance;
            if (ethUsed <= msg.value) {
                uint256 refundAmount = msg.value - ethUsed;
                if (refundAmount > 0) {
                    (bool success,) = msg.sender.call{value: refundAmount}("");
                    if (!success) revert RefundFailed(refundAmount, msg.sender);
                }
            }

            emit ManagerDeployed(originalCreator, revenueManager, memecoin, tokenId);
            return (revenueManager, memecoin);
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Initialize failed: ", reason)));
        }
    }

    function deployExistingFlaunch(
        address _memecoin
    ) external payable nonReentrant returns (address manager, address memecoin) {
        if (revenueManagerImplementation == address(0)) revert ImplementationNotSet("Revenue manager implementation address not configured");
        if (msg.sender == address(0)) revert InvalidAddress(msg.sender, "Owner address cannot be zero");
        uint256 startBalance = address(this).balance;

        // Store original creator
        address originalCreator = msg.sender;

        // Get Flaunch contract and tokenId
        IFlaunch flaunch = premineZap.flaunchContract();
        uint256 tokenId = flaunch.tokenId(_memecoin);

        // Ownership check
        require(IERC721(address(flaunch)).ownerOf(tokenId) == msg.sender, "Caller is not the token owner");

        memecoin = _memecoin;

        // Deploy manager 
        address payable revenueManager = treasuryFactory.deployManager(revenueManagerImplementation);

        // Approve the revenue manager to use our tokenId
        flaunch.approve{value: 0}(revenueManager, tokenId);

        // Initialize manager
        try IRevenueManager(revenueManager).initialize(
            tokenId,
            address(this),
            abi.encode(IRevenueManager.InitParams({
                creator: payable(originalCreator),
                protocolRecipient: payable(platformFeeReceiver),
                protocolFee: platformFeeBps
            }))
        ) {
            // Update tracking relationships
            isRegisteredManager[revenueManager] = true;
            creatorToManagers[originalCreator].push(revenueManager);
            memecoinToManager[memecoin] = revenueManager;
            managerToMemecoin[revenueManager] = memecoin;

            // Refund excess ETH if any
            uint256 ethUsed = startBalance + msg.value - address(this).balance;
            if (ethUsed <= msg.value) {
                uint256 refundAmount = msg.value - ethUsed;
                if (refundAmount > 0) {
                    (bool success,) = msg.sender.call{value: refundAmount}("");
                    if (!success) revert RefundFailed(refundAmount, msg.sender);
                }
            }

            emit ManagerDeployed(originalCreator, revenueManager, memecoin, tokenId);
            return (revenueManager, memecoin);
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Initialize failed: ", reason)));
        }
    }

    function claimFees(address manager) external nonReentrant {
        if (!isRegisteredManager[manager]) revert NotRegisteredManager(manager);
        IRevenueManager revenueManager = IRevenueManager(manager);
        if (msg.sender != address(revenueManager.creator())) revert NotCreator(msg.sender, address(revenueManager.creator()));

        // Call claim on revenue manager
        revenueManager.claim();
    }

    function transferCreatorRights(
        address manager,
        address payable newCreator
    ) external {
        if (!isRegisteredManager[manager]) revert InvalidManager(manager, "Not registered");
        if (newCreator == address(0)) revert InvalidAddress(newCreator, "Creator address cannot be zero");

        // Verify caller is current creator
        IRevenueManager revenueManager = IRevenueManager(manager);
        if (msg.sender != address(revenueManager.creator())) revert NotCreator(msg.sender, address(revenueManager.creator()));

        // Update creator in manager
        revenueManager.setCreator(payable(newCreator));

        // Update our tracking
        address oldCreator = msg.sender;
        
        // Remove from old creator's list
        address[] storage oldManagers = creatorToManagers[oldCreator];
        uint256 length = oldManagers.length;
        for (uint i = 0; i < length; i++) {
            if (oldManagers[i] == manager) {
                if (i != length - 1) {
                    oldManagers[i] = oldManagers[length - 1];
                }
                oldManagers.pop();
                break;
            }
        }

        // Add to new creator's list
        creatorToManagers[newCreator].push(manager);
    }

    // Admin Functions
    function setRevenueManagerImplementation(address _implementation) external onlyRole(ADMIN_ROLE) {
        if (_implementation == address(0)) revert InvalidAddress(_implementation, "Implementation cannot be zero");
        address oldImplementation = revenueManagerImplementation;
        revenueManagerImplementation = _implementation;
        
        emit RevenueManagerImplementationUpdated(oldImplementation, _implementation);
    }

    function setTreasuryFactory(address _treasuryFactory) external onlyRole(ADMIN_ROLE) {
        if (_treasuryFactory == address(0)) revert InvalidAddress(_treasuryFactory, "Treasury factory cannot be zero");
        address oldFactory = address(treasuryFactory);
        treasuryFactory = ITreasuryManagerFactory(_treasuryFactory);
        
        emit TreasuryFactoryUpdated(oldFactory, _treasuryFactory);
    }

    function setPremineZap(address _premineZap) external onlyRole(ADMIN_ROLE) {
        if (_premineZap == address(0)) revert InvalidAddress(_premineZap, "Premine zap cannot be zero");
        address oldZap = address(premineZap);
        premineZap = IPremineZap(_premineZap);
        
        emit PremineZapUpdated(oldZap, _premineZap);
    }

    function updatePlatformFeeReceiver(address newReceiver) external onlyRole(FEE_MANAGER_ROLE) {
        if (newReceiver == address(0)) revert InvalidAddress(newReceiver, "Fee receiver cannot be zero");
        address oldReceiver = platformFeeReceiver;
        platformFeeReceiver = newReceiver;

        emit PlatformFeeReceiverUpdated(oldReceiver, newReceiver);
    }

    function updatePlatformFee(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        require(newFeeBps <= 10000, "Fee cannot exceed 100%");
        uint256 oldFee = platformFeeBps;
        platformFeeBps = newFeeBps;

        emit PlatformFeeUpdated(oldFee, newFeeBps);
    }

    function rescueNFT(
        address manager,
        address recipient
    ) external onlyRole(ADMIN_ROLE) {
        if (!isRegisteredManager[manager]) revert InvalidManager(manager, "Not registered");
        if (recipient == address(0)) revert InvalidAddress(recipient, "Creator address cannot be zero");

        // Get token ID
        IRevenueManager revenueManager = IRevenueManager(manager);
        uint256 tokenId = revenueManager.tokenId();

        // Call rescue on the manager
        ITreasuryManager(manager).rescue(tokenId, recipient);

        // Clean up our tracking
        address creator = revenueManager.creator();
        address[] storage managers = creatorToManagers[creator];
        for (uint i = 0; i < managers.length; i++) {
            if (managers[i] == manager) {
                managers[i] = managers[managers.length - 1];
                managers.pop();
                break;
            }
        }
        isRegisteredManager[manager] = false;
    }

    function recoverStuckNFT(
        address nftContract,
        uint256 tokenId,
        address to
    ) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert InvalidAddress(to, "Recipient cannot be zero");
        
        // Try to transfer the NFT
        try IERC721(nftContract).transferFrom(address(this), to, tokenId) {
            emit NFTRecovered(nftContract, tokenId, to);
        } catch {
            revert NFTTransferFailed(address(this), to, tokenId);
        }
    }

    function recoverAsset(address tokenAddress, address payable recipient, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        
        if (tokenAddress == address(0)) {
            // Recover ETH
            if (amount == 0 || amount > address(this).balance) 
                revert InvalidAmount(amount, address(this).balance);
                
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert TransferFailed(address(0), recipient, amount);
            
            emit AssetRecovered(address(0), recipient, amount);
        } else {
            // Recover ERC20
            IERC20 token = IERC20(tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            
            if (amount == 0 || amount > balance) 
                revert InvalidAmount(amount, balance);
                
            bool success = token.transfer(recipient, amount);
            if (!success) revert TransferFailed(tokenAddress, recipient, amount);
            
            emit AssetRecovered(tokenAddress, recipient, amount);
        }
    }

    // View Functions
    function getCreatorManagers(address creator) external view returns (
        address[] memory managers,
        address[] memory memecoinAddresses,
        uint256[] memory tokenIds
    ) {
        managers = creatorToManagers[creator];
        memecoinAddresses = new address[](managers.length);
        tokenIds = new uint256[](managers.length);

        for (uint i = 0; i < managers.length; i++) {
            memecoinAddresses[i] = managerToMemecoin[managers[i]];
            tokenIds[i] = IRevenueManager(managers[i]).tokenId();
        }
    }

    function getManagerDetails(address manager) external view returns (
        address creator,
        uint256 tokenId,
        address memecoin
    ) {
        if (!isRegisteredManager[manager]) revert InvalidManager(manager, "Not registered");
        
        memecoin = managerToMemecoin[manager];

        IRevenueManager revenueManager = IRevenueManager(manager);
        creator = address(revenueManager.creator());
        tokenId = revenueManager.tokenId();
    }

    function getClaimableInfo(
        address manager
    ) external view returns (
        uint256 creatorAmount,
        uint256 protocolAmount,
        address creator,
        address protocolRecipient,
        uint256 protocolFee
    ) {
        if (!isRegisteredManager[manager]) revert InvalidManager(manager, "Not registered");
        IRevenueManager revenueManager = IRevenueManager(manager);
        
        creator = revenueManager.creator();
        protocolRecipient = revenueManager.protocolRecipient();
        protocolFee = revenueManager.protocolFee();
        
        // Get the position manager contract
        IPositionManager positionManager = premineZap.positionManager();
        
        // Get claimable fees balance from the position manager contract
        uint256 balance = positionManager.balances(manager);

        // Calculate fee splits based on protocol fee percentage
        if (balance > 0) {
            protocolAmount = (balance * protocolFee) / 10000;
            creatorAmount = balance - protocolAmount;
        }
    }

    // Helper functions
    function calculateFlaunchFee(
        uint256 premineAmount,
        uint256 slippage,
        bytes memory initialPriceParams
    ) external view returns (uint256 ethRequired) {
        return premineZap.calculateFee(
            premineAmount,
            slippage,
            initialPriceParams
        );
    }

    function getPositionManager() external view returns (IPositionManager) {
        return premineZap.positionManager();
    }

    function getFlaunchContract() external view returns (IFlaunch) {
        return premineZap.flaunchContract();
    }

    function getTokenInfo(address memecoin) external view returns (
        uint256 tokenId,
        address manager,
        address creator
    ) {
        manager = memecoinToManager[memecoin];
        if (manager != address(0)) {
            tokenId = IFlaunch(premineZap.flaunchContract()).tokenId(memecoin);
            creator = IRevenueManager(manager).creator();
        }
    }

    function isAgentStudioToken(address memecoin) external view returns (bool) {
        return memecoinToManager[memecoin] != address(0);
    }

    receive() external payable {}
}
