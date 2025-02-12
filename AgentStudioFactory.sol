// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IToken {
    function treasury() external view returns (address payable);
    function creator() external view returns (address);
    function flaunch() external view returns (address);
}

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

    function withdrawFees(address to, bool wrap) external;
    function getFlaunchingFee(bytes memory initialPriceParams) external view returns (uint256);

    event PoolCreated(
        bytes32 indexed _poolId,
        address _memecoin,
        address _memecoinTreasury,
        uint256 _tokenId,
        bool _currencyFlipped,
        uint256 _flaunchFee,
        FlaunchParams _params
    );
}

interface IPremineZap {
    function calculateFee(
        uint256 _premineAmount,
        uint256 _slippage,
        bytes memory _initialPriceParams
    ) external view returns (uint256 ethRequired_);
    
    function flaunch(
        IPositionManager.FlaunchParams calldata _params
    ) external payable returns (address memecoin_, uint256 ethSpent_);
    
    function positionManager() external view returns (IPositionManager);
}

interface IFlaunch is IERC721 {
    function positionManager() external view returns (IPositionManager);
    function tokenId(address _memecoin)external view returns (uint256 _tokenId);
}

/**
 * @title AgentStudioEscrow
 * @notice Escrow contract for Agent Studio platform built on top of Flaunch
 */
contract AgentStudioEscrow is AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    struct InitParams {
        address flaunch;
        address platformFeeReceiver;
        uint256 initialFeeBps;
        address deployer;
        address specifiedCreator;
        address admin;
    }
    
    address public factory;
    IFlaunch public flaunch;
    address payable public platformFeeReceiver;
    uint256 public platformFeeBps;
    address public deployer;        // The address that initiated the flaunch (msg.sender)
    address public specifiedCreator; // The creator address specified in params
    uint256 public tokenId;
    address public memecoinAddress;
    bool private initialized;
    
    mapping(address => uint256) public creatorEarnings;
    mapping(address => uint256) public platformEarnings;
    
    event FeeClaimed(address indexed recipient, uint256 amount);
    event PlatformFeeClaimed(address indexed recipient, uint256 amount);
    event PlatformFeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event CreatorUpdated(address indexed oldCreator, address indexed newCreator);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event TokenRescued(uint256 indexed tokenId, address indexed to);

    error InvalidFee();
    error NotAuthorized();
    error TransferFailed();
    error AlreadyInitialized();

    modifier onlySpecifiedCreator() {
        if (msg.sender != specifiedCreator) revert NotAuthorized();
        _;
    }

    constructor(address _admin) {
        // This constructor only sets up initial admin roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(FEE_MANAGER_ROLE, _admin);
    }

    function initialize(
        InitParams calldata params
    ) external {
        if (initialized) revert AlreadyInitialized();
        require(params.initialFeeBps <= 10000, "Fee cannot exceed 100%");
        
        flaunch = IFlaunch(params.flaunch);
        platformFeeReceiver = payable(params.platformFeeReceiver);
        platformFeeBps = params.initialFeeBps;
        deployer = params.deployer;
        specifiedCreator = params.specifiedCreator;
        factory = params.admin;

        _grantRole(DEFAULT_ADMIN_ROLE, params.admin);
        _grantRole(ADMIN_ROLE, params.admin);
        _grantRole(FEE_MANAGER_ROLE, params.admin);
        
        initialized = true;
    }

    function setTokenInfo(address _memecoinAddress, uint256 _tokenId) external onlyRole(ADMIN_ROLE) {
        require(tokenId == 0, "Token already set");
        require(_memecoinAddress != address(0), "Invalid address");
        
        // Verify the token's creator matches this escrow contract
        address tokenCreator = IToken(_memecoinAddress).creator();
        require(tokenCreator == address(this), "Creator mismatch");
        
        memecoinAddress = _memecoinAddress;
        tokenId = _tokenId;
    }

    function claimFees() external nonReentrant onlySpecifiedCreator {
        require(tokenId != 0, "Token not set");
        uint256 startBalance = address(this).balance;
        
        // Claim fees from Flaunch
        flaunch.positionManager().withdrawFees(address(this), true);
        
        uint256 newFees = address(this).balance - startBalance;
        if (newFees == 0) return;

        // Calculate fee split
        uint256 platformFee = (newFees * platformFeeBps) / 10000;
        uint256 creatorFee = newFees - platformFee;

        // Update earnings trackers
        platformEarnings[platformFeeReceiver] += platformFee;
        creatorEarnings[specifiedCreator] += creatorFee;

        // Update factory's platform earnings tracking
        AgentStudioFactory(payable(factory)).updatePlatformEarnings(platformFee);

        // Transfer fees
        if (platformFee > 0) {
            (bool platformSuccess,) = platformFeeReceiver.call{value: platformFee}("");
            if (!platformSuccess) revert TransferFailed();
            emit PlatformFeeClaimed(platformFeeReceiver, platformFee);
        }

        if (creatorFee > 0) {
            (bool creatorSuccess,) = specifiedCreator.call{value: creatorFee}("");
            if (!creatorSuccess) revert TransferFailed();
            emit FeeClaimed(specifiedCreator, creatorFee);
        }
    }

    function updateCreator(address newCreator) external onlySpecifiedCreator {
        require(newCreator != address(0), "Invalid address");
        address oldCreator = specifiedCreator;
        specifiedCreator = newCreator;

        AgentStudioFactory(payable(factory)).updateCreatorTracking(
            oldCreator,
            newCreator,
            address(this)
        );

        emit CreatorUpdated(specifiedCreator, newCreator);
    }

    function updatePlatformFeeReceiver(address newReceiver) external onlyRole(FEE_MANAGER_ROLE) {
        require(newReceiver != address(0), "Invalid address");
        address oldReceiver = platformFeeReceiver;
        platformFeeReceiver = payable(newReceiver);
        emit PlatformFeeReceiverUpdated(oldReceiver, newReceiver);
    }

    function updatePlatformFee(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFeeBps > 10000) revert InvalidFee();
        uint256 oldFee = platformFeeBps;
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(oldFee, newFeeBps);
    }

    function getCreatorInfo() external view returns (
        address _deployer,
        address _creator,
        address _memecoin,
        uint256 _tokenId
    ) {
        return (deployer, specifiedCreator, memecoinAddress, tokenId);
    }

    function rescueToken(address to) external onlyRole(ADMIN_ROLE) {
        require(to != address(0), "Invalid address");
        require(tokenId != 0, "No token to rescue");
        
        flaunch.transferFrom(address(this), to, tokenId);
        emit TokenRescued(tokenId, to);
    }

    receive() external payable {}
}

/**
 * @title AgentStudioFactory
 * @notice Factory contract for creating and managing Flaunch tokens through escrow
 */
contract AgentStudioFactory is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    IPremineZap public immutable flaunchPremineZap;
    address public immutable escrowImplementation;
    address public platformFeeReceiver;
    uint256 public platformFeeBps;

    mapping(address => address) public deployerToEscrow;
    mapping(address => address) public specifiedCreatorToEscrow;
    mapping(address => bool) public isRegisteredEscrow;
    mapping(address => address) public memecoinToEscrow;
    mapping(address => uint256) public totalPlatformEarnings;

    event EscrowDeployed(
        address indexed deployer,
        address indexed specifiedCreator,
        address indexed escrow
    );
    event TokenFlaunched(
        address indexed deployer,
        address indexed specifiedCreator,
        address indexed escrow,
        address memecoin,
        uint256 tokenId
    );
    event PlatformFeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(
        address _flaunchPremineZap,
        address _platformFeeReceiver,
        uint256 _initialFeeBps
    ) {
        require(_initialFeeBps <= 10000, "Fee cannot exceed 100%");
        
        flaunchPremineZap = IPremineZap(_flaunchPremineZap);
        platformFeeReceiver = _platformFeeReceiver;
        platformFeeBps = _initialFeeBps;

        // Deploy the implementation contract
        escrowImplementation = address(new AgentStudioEscrow(address(this)));

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
    }

    function deployAndFlaunch(
        IPositionManager.FlaunchParams calldata flaunchParams
    ) external payable returns (address escrow, address memecoin) {
        // Store the initial balance before operations
        uint256 initialBalance = address(this).balance - msg.value;

        // First create the escrow
        escrow = Clones.clone(escrowImplementation);
        
        // Track relationships
        deployerToEscrow[msg.sender] = escrow;
        specifiedCreatorToEscrow[flaunchParams.creator] = escrow;
        isRegisteredEscrow[escrow] = true;

        emit EscrowDeployed(msg.sender, flaunchParams.creator, escrow);

        // Modify flaunch params to use escrow as creator
        IPositionManager.FlaunchParams memory modifiedParams = flaunchParams;
        modifiedParams.creator = escrow;

        // Calculate fees
        uint256 flaunchingFee = flaunchPremineZap.positionManager().getFlaunchingFee(
            modifiedParams.initialPriceParams
        );

        uint256 premineFee = 0;
        if (modifiedParams.premineAmount > 0) {
            premineFee = flaunchPremineZap.calculateFee(
                modifiedParams.premineAmount,
                0, // no slippage
                modifiedParams.initialPriceParams
            );
        }

        require(msg.value >= flaunchingFee + premineFee, "Insufficient ETH");

        // Flaunch the token through PremineZap
        (address _memecoin, uint256 ethSpent) = flaunchPremineZap.flaunch{value: msg.value}(
            modifiedParams
        );
        memecoin = _memecoin;

        // Track memecoin to escrow relationship
        memecoinToEscrow[memecoin] = escrow;

        // Get flaunch address from the token contract itself
        address flaunch = IToken(memecoin).flaunch();

        // Get token ID from the token contract itself
        uint256 tokenId = IFlaunch(flaunch).tokenId(memecoin);

        // Initialize escrow with all parameters
        AgentStudioEscrow(payable(escrow)).initialize(
            AgentStudioEscrow.InitParams({
                flaunch: address(flaunch),
                platformFeeReceiver: platformFeeReceiver,
                initialFeeBps: platformFeeBps,
                deployer: msg.sender, // actual deployer
                specifiedCreator: flaunchParams.creator, // specified creator
                admin: address(this)
            })
        );

        AgentStudioEscrow(payable(escrow)).setTokenInfo(memecoin, tokenId);

        // Refund excess ETH if any
        uint256 currentBalance = address(this).balance;
        uint256 refundAmount = currentBalance - initialBalance;
        if (refundAmount > 0) {
            (bool success,) = msg.sender.call{value: refundAmount}("");
            require(success, "Refund failed");
        }

        emit TokenFlaunched(msg.sender, flaunchParams.creator, escrow, memecoin, tokenId);
    }

    function updateCreatorTracking(address oldCreator, address newCreator, address escrow) external {
        // Only registered escrow contracts can call this
        require(isRegisteredEscrow[msg.sender], "Not authorized");
        
        // Remove old mapping
        if (specifiedCreatorToEscrow[oldCreator] == escrow) {
            specifiedCreatorToEscrow[oldCreator] = address(0);
        }
        
        // Set new mapping
        specifiedCreatorToEscrow[newCreator] = escrow;
    }

    function getEscrowForAccount(address account) external view returns (address escrow) {
        escrow = deployerToEscrow[account];
        if (escrow == address(0)) {
            escrow = specifiedCreatorToEscrow[account];
        }
    }

    function getEscrowForMemecoin(address memecoin) external view returns (address) {
        return memecoinToEscrow[memecoin];
    }

    function updatePlatformEarnings(uint256 amount) external {
        // Only registered escrow contracts can call this
        require(isRegisteredEscrow[msg.sender], "Not authorized");
        
        // Update the total earnings for the current platform fee receiver
        totalPlatformEarnings[platformFeeReceiver] += amount;
    }

    function updatePlatformFeeReceiver(address newReceiver) external onlyRole(FEE_MANAGER_ROLE) {
        require(newReceiver != address(0), "Invalid address");
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

    receive() external payable {}
}
