// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin contracts (install @openzeppelin/contracts)
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RavenAccessWithSubgraphHooks is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Payment tokens (Base chain USDC/USDT)
    IERC20 public immutable USDC;
    IERC20 public immutable USDT;

    // Engagement Constant Hashed
    bytes32 public constant LIKE = keccak256("like");
    bytes32 public constant COMMENT = keccak256("comment");
    bytes32 public constant REPOST = keccak256("repost");
    bytes32 public constant YAP = keccak256("yap");
    bytes32 public constant NEW_USER_BONUS = keccak256("new_user_bonus");
    bytes32 public constant REFERRAL_YOU_REFER = keccak256("referral_you_refer");
    bytes32 public constant REFERRAL_YOU_ARE_REFERRED = keccak256("referral_you_are_referred");

    // Treasury multisig recommended
    address public treasury;

    // Optional oracle/back-end allowed to award credits and update user memory pointers
    address public oracle;

    // Subscription plan
    struct SubscriptionPlan {
        uint256 priceUnits; // in token smallest unit (USDC/USDT decimals)
        uint256 monthlyCap; // requests per 30-day window
        bool active;
    }
    mapping(uint8 => SubscriptionPlan) public plans;

    // User subscription state
    struct UserSubscription {
        uint8 planId;           // 0 = none
        uint256 startTimestamp; // anchor for 30-day window
        uint256 usedThisWindow;
        uint256 lastRenewedAt;  // last subscription purchase timestamp
    }
    mapping(address => UserSubscription) public subscriptions;

    // Credits (points) shown on dashboard
    mapping(address => uint256) public credits;
    // ADD XP mapping after credits maping (around line 41)
    mapping(address => uint256) public xp;

    // Costs (credits) for inference modes
    uint256 public constant COST_BASIC = 1;
    uint256 public constant COST_TAGS = 2;
    uint256 public constant COST_PRICE_ACCURACY = 4;
    uint256 public constant COST_FULL = 6;

    // Global price-accuracy per-plan cap enforcement
    uint256 public GLOBAL_PRICE_ACCURACY_CAP = 3000;

	// IMPLEMENT: per-user monotonic sequence to allow subgraphs to order events reliably
    mapping(address => uint256) public userSequence;

    // -----------------------
    // Events (rich for subgraph)
    // -----------------------
    // Emitted when credits change; reason helps subgraph categorize (referral, quest, admin, consumed)
    event CreditsChanged(address indexed user, int256 delta, uint256 newBalance, string reason, address indexed by, uint256 seq);

    // Emitted when multiple credits awarded in batch for gas efficiency
    event CreditsBatchChanged(address[] users, uint256[] amounts, string reason, address indexed by);

    // Subscription lifecycle
    event SubscriptionPurchased(address indexed user, uint8 indexed planId, address token, uint256 paidUnits, uint256 startTimestamp, uint256 seq);
    event SubscriptionRenewed(address indexed user, uint8 indexed planId, uint256 paidUnits, uint256 renewedAt, uint256 seq);
    event SubscriptionCancelled(address indexed user, uint8 indexed planId, uint256 cancelledAt, uint256 seq);

    // Inference log - each inference request creates an event with optional off-chain contextHash
    // contextHash: Neo4j snapshot pointer that merges model input/output & memory snapshot
    event InferenceLog(
        address indexed user,
        string mode,
        uint256 quantity,
        bool billedToSubscription,
        uint256 creditsCharged,
        uint8 subscriptionPlan , //If subscriptionplanId=None*CreditAvailable_Inference available_BoundWithCreditAvailable
        uint256 subscriptionWindowUsed,
        string contextHash,
        uint256 timestamp,
        uint256 seq
    );

    // User memory pointer update event (backend writes content-hash, subG graph)
    event UserMemoryUpdated(address indexed user, string memoryHash, uint256 updatedAt, address indexed by, uint256 seq);

    // Plan and admin events
    event PlanSet(uint8 indexed planId, uint256 priceUnits, uint256 monthlyCap, bool active);
    event OracleSet(address indexed oracle);
    event TreasurySet(address indexed treasury);
    event GlobalPriceAccuracyCapUpdated(uint256 cap);

    // Add XP Evetns after CreditsBatchChanged event
    event XPChanged(address indexed user, int256 delta, uint256 newBalance, string reason, address indexed by , uint256 seq);
    event XPBatchChanged(address[] users, uint256[] amounts, string reason, address indexed by);


    // -----------------------
    // Constructor & init
    // -----------------------
    constructor(address _usdc, address _usdt, address _treasury, address _oracle) Ownable(msg.sender) {
        require(_usdc != address(0) && _usdt != address(0) && _treasury != address(0), "zero address");
        USDC = IERC20(_usdc);
        USDT = IERC20(_usdt);
        treasury = _treasury;
        oracle = _oracle;

        // default plans: priceUnits in smallest token units (6 decimals for USDC/USDT)
        // Plan 1: Price Accuracy - $99/month, 3000 requests
        plans[1] = SubscriptionPlan({priceUnits: 99 * 10**6, monthlyCap: 3000, active: true});
        // Plan 2: Price Accuracy + Reasoning - $129/month, 4000 requests
        plans[2] = SubscriptionPlan({priceUnits: 129 * 10**6, monthlyCap: 4000, active: true});
        // Plan 3: Price Accuracy + Reasoning + Scores - $149/month, 5000 requests
        plans[3] = SubscriptionPlan({priceUnits: 149 * 10**6, monthlyCap: 5000, active: true});
    }

    // -----------------------
    // Modifiers
    // -----------------------
    modifier onlyOracleOrOwner() {
        require(msg.sender == oracle || msg.sender == owner(), "only oracle or owner");
        _;
    }

    // Add After awardCreditBatch function
    function _isEngagementAction(string calldata reason) internal pure returns (bool){
        bytes32 reasonHash = keccak256(bytes(reason));
        return reasonHash == LIKE ||
        reasonHash == COMMENT ||
        reasonHash == REPOST ||
        reasonHash == YAP ||
        reasonHash == NEW_USER_BONUS ||
        reasonHash == REFERRAL_YOU_REFER ||
        reasonHash == REFERRAL_YOU_ARE_REFERRED;
    }

    // -----------------------
    // Admin functions
    // -----------------------
    function setPlan(uint8 planId, uint256 priceUnits, uint256 monthlyCap, bool active) external onlyOwner {
        require(planId >= 1, "invalid id");
        plans[planId] = SubscriptionPlan({priceUnits: priceUnits, monthlyCap: monthlyCap, active: active});
        emit PlanSet(planId, priceUnits, monthlyCap, active);
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
        emit OracleSet(_oracle);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setGlobalPriceAccuracyCap(uint256 cap) external onlyOwner {
        GLOBAL_PRICE_ACCURACY_CAP = cap;
        emit GlobalPriceAccuracyCapUpdated(cap);
    }

    // -----------------------
    // Credits awarding (backend/oracle pushes; visible on dashboard via public mapping)
    // -----------------------
    function awardCredits(address user, uint256 amount, string calldata reason) external whenNotPaused nonReentrant onlyOracleOrOwner {
        require(user != address(0), "zero");
        require(amount > 0, "zero amount");
        credits[user] += amount;

        // bump user sequence for ordering in subgraph
        userSequence[user] += 1;

        // Award XP only for engagement actions: XP = Credits * 2
        if (_isEngagementAction(reason)){
            uint256 xpAmount = amount * 2;
            xp[user] += xpAmount;
            emit XPChanged(user, int256(xpAmount), xp[user], reason, msg.sender, userSequence[user]);
        }

        emit CreditsChanged(user, int256(amount), credits[user], reason, msg.sender, userSequence[user]);
    }

    function awardCreditsBatch(address[] calldata users, uint256[] calldata amounts, string calldata reason) external whenNotPaused nonReentrant onlyOracleOrOwner {
        require(users.length == amounts.length, "len mismatch");
        
        bool isEngagementAction = _isEngagementAction(reason);
        uint256[] memory xpAmounts = new uint256[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            uint256 a = amounts[i];
            if (u == address(0) || a == 0) continue;
            credits[u] += a;
            
            // Award XP only for engagement actions: XP = Credits * 2
            if (isEngagementAction) {
                uint256 xpAmount = a * 2;
                xpAmounts[i] = xpAmount;
                xp[u] += xpAmount;
            } else {
                xpAmounts[i] = 0;
            }
            
            userSequence[u] += 1;
            emit CreditsChanged(u, int256(a), credits[u], reason, msg.sender, userSequence[u]);
            
            // Emit XP event if engagement action
            if (isEngagementAction && xpAmounts[i] > 0) {
                emit XPChanged(u, int256(xpAmounts[i]), xp[u], reason, msg.sender, userSequence[u]);
            }
        }

        emit CreditsBatchChanged(users, amounts, reason, msg.sender);
        if (isEngagementAction) {
            emit XPBatchChanged(users, xpAmounts, reason, msg.sender);
        }
    }


/// Increase user credits (oracle or owner)
function increaseCredits(address user, uint256 amount, string calldata reason) external whenNotPaused nonReentrant onlyOracleOrOwner {
    require(user != address(0), "zero user");
    require(amount > 0, "zero amount");
    credits[user] += amount;
    userSequence[user] += 1;
    emit CreditsChanged(user, int256(amount), credits[user], reason, msg.sender, userSequence[user]);
}

///  Set user credits to an exact value. Only owner (multisig recommended).
function setCredits(address user, uint256 newBalance, string calldata reason) external onlyOwner whenNotPaused nonReentrant {
    require(user != address(0), "zero user");
    credits[user] = newBalance;
    userSequence[user] += 1;
    // emit delta as signed int for historical clarity
    emit CreditsChanged(user, int256(newBalance), credits[user], reason, msg.sender, userSequence[user]);
}

    // -----------------------
    // User memory pointer updates (backend writes IPFS/arweave hash for dashboard/subgraph)
    // -----------------------
    function updateUserMemoryPointer(address user, string calldata memoryHash) external whenNotPaused nonReentrant onlyOracleOrOwner {
        require(user != address(0), "zero");
        // The contract only emits the pointer; the subgraph will index this and map to the user's on-chain state
        userSequence[user] += 1;
        emit UserMemoryUpdated(user, memoryHash, block.timestamp, msg.sender, userSequence[user]);
    }

    // -----------------------
    // Subscription purchase (USDC/USDT only)
    // -----------------------
    function purchaseSubscriptionWithToken(uint8 planId, IERC20 token, uint256 amountUnits) external whenNotPaused nonReentrant {
        require(planId >= 1, "invalid plan");
        SubscriptionPlan memory p = plans[planId];
        require(p.active, "inactive plan");
        require(address(token) == address(USDC) || address(token) == address(USDT), "unsupported token");
        require(amountUnits >= p.priceUnits, "insufficient payment");

        // transfer payment to treasury
        token.safeTransferFrom(msg.sender, treasury, amountUnits);

        // set subscription state and reset window
        subscriptions[msg.sender] = UserSubscription({
            planId: planId,
            startTimestamp: block.timestamp,
            usedThisWindow: 0,
            lastRenewedAt: block.timestamp
        });

        userSequence[msg.sender] += 1;
        emit SubscriptionPurchased(msg.sender, planId, address(token), amountUnits, block.timestamp, userSequence[msg.sender]);
    }

    // Optionally allow owner/oracle to renew subscription on behalf of user (e.g., promotional)
    function renewSubscriptionFor(address user, uint8 planId, uint256 paidUnits) external onlyOracleOrOwner whenNotPaused nonReentrant {
        SubscriptionPlan memory p = plans[planId];
        require(p.active, "inactive");
        subscriptions[user] = UserSubscription({
            planId: planId,
            startTimestamp: block.timestamp,
            usedThisWindow: 0,
            lastRenewedAt: block.timestamp
        });
        userSequence[user] += 1;
        emit SubscriptionRenewed(user, planId, paidUnits, block.timestamp, userSequence[user]);
    }

    function cancelSubscription() external whenNotPaused nonReentrant {
        UserSubscription memory old = subscriptions[msg.sender];
        subscriptions[msg.sender] = UserSubscription({planId: 0, startTimestamp: 0, usedThisWindow: 0, lastRenewedAt: old.lastRenewedAt});
        userSequence[msg.sender] += 1;
        emit SubscriptionCancelled(msg.sender, old.planId, block.timestamp, userSequence[msg.sender]);
    }

    // -----------------------
    // Inference consumption logic (prefers Credits over SubscriptionPlan , if credits not available prefer SubscriptionPlan)
    // - contextHash is optional pointer to off-chain snapshot (IPFS) that subgraph ties to this event
    // -----------------------
    function _monthWindowStart(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / 30 days) * 30 days;
    }

    function _ensureWindowReset(UserSubscription storage us) internal {
        if (us.startTimestamp == 0) return;
        uint256 lastWindow = _monthWindowStart(us.startTimestamp);
        uint256 currentWindow = _monthWindowStart(block.timestamp);
        if (currentWindow > lastWindow) {
            us.usedThisWindow = 0;
            us.startTimestamp = block.timestamp;
        }
    }

    function requestInference(string calldata mode, uint256 quantity, string calldata contextHash) external whenNotPaused nonReentrant {
        require(quantity > 0, "quantity > 0");

        bytes32 m = keccak256(bytes(mode));
        uint256 costCredits;
        bool isPriceAccuracyMode = false;

        if (m == keccak256("basic")) {
            costCredits = COST_BASIC * quantity;
        } else if (m == keccak256("tags")) {
            costCredits = COST_TAGS * quantity;
        } else if (m == keccak256("price_accuracy")) {
            costCredits = COST_PRICE_ACCURACY * quantity;
            isPriceAccuracyMode = true;
        } else if (m == keccak256("full")) {
            costCredits = COST_FULL * quantity;
            isPriceAccuracyMode = true; // Full mode includes price accuracy
        } else {
            revert("unknown mode");
        }

        UserSubscription storage us = subscriptions[msg.sender];
        bool billedToSubscription = false;
        uint256 creditsCharged = 0;

        // Try subscription consumption
        if (us.planId != 0) {
            _ensureWindowReset(us);
            uint256 planCap = plans[us.planId].monthlyCap;

            // Apply 3000 cap for price accuracy features across all subscription plans
            uint256 effectiveCap = isPriceAccuracyMode ? GLOBAL_PRICE_ACCURACY_CAP : planCap;

            if (us.usedThisWindow + quantity <= effectiveCap) {
                us.usedThisWindow += quantity;
                billedToSubscription = true;
            }
        }

        // FIXED: Use require instead of return
        if (!billedToSubscription) {
            require(credits[msg.sender] >= costCredits, "insufficient credits");
            credits[msg.sender] -= costCredits;
            creditsCharged = costCredits;
            userSequence[msg.sender] += 1;
            emit CreditsChanged(msg.sender, -int256(costCredits), credits[msg.sender], "consumed", msg.sender, userSequence[msg.sender]);
        }

        userSequence[msg.sender] += 1;
        emit InferenceLog(
            msg.sender,
            mode,
            quantity,
            billedToSubscription,
            creditsCharged,
            us.planId,
            us.usedThisWindow,
            contextHash,
            block.timestamp,
            userSequence[msg.sender]
        );
    }


    // -----------------------
    // View helpers for dashboard/subgraph convenience
    // -----------------------
    function getUserXP(address user) external view returns(uint256){
        return xp[user];
    }

    // -----------------------
    // View helpers for dashboard/subgraph convenience
    // -----------------------
    function getUserCredits(address user) external view returns (uint256) {
        return credits[user];
    }

    function getUserSubscription(address user) external view returns (
        uint8 planId,
        uint256 startTs,
        uint256 usedThisWindow,
        uint256 lastRenewedAt,
        uint256 planMonthlyCap,
        uint256 planPriceUnits
    ) {
        UserSubscription memory us = subscriptions[user];
        planId = us.planId;
        startTs = us.startTimestamp;
        usedThisWindow = us.usedThisWindow;
        lastRenewedAt = us.lastRenewedAt;
        planMonthlyCap = us.planId == 0 ? 0 : plans[us.planId].monthlyCap;
        planPriceUnits = us.planId == 0 ? 0 : plans[us.planId].priceUnits;
    }

    // Helper to increase credits for on-chain testing (onlyOwner)
    function ownerMintCredits(address user, uint256 amount, string calldata note) external onlyOwner {
        credits[user] += amount;
        userSequence[user] += 1;
        emit CreditsChanged(user, int256(amount), credits[user], note, msg.sender, userSequence[user]);
    }
}
