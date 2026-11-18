// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Crumble Arena — Pico Park-style co-op platformer on BNB Chain, Agent ID as identity.
/// @notice Gas-only. No token, no entry fees, no prize pool, no approvals, no fund custody.
///         Rewards are on-chain XP, levels, badges and leaderboard rank.
/// @dev Agent ID contract (SPACE ID Agent ID, ERC-721, non-transferable):
///      0x60b9262456de011f7d15a54cdd8c48baaa8b022f
///      Agent ID tokenId = uint256(keccak256(handle)), e.g. "danzz" ->
///      0xe5ada7841a386a460015a74dfe65f0008ca5eeedc714b2f034333270ecf01733
///      (verified on BSC mainnet 18 Nov 2026: ownerOf(tokenId) = danzz.ai wallet,
///      handleOf(wallet) = "danzz", tokenURI = https://agentid.prd.space.id/metadata/danzz.json).
///      Owner powers (disclosed, see README): pause/unpause + season epoch only.
///      Owner CANNOT mint anything, move user funds (there are none), change XP rules,
///      freeze a profile, or upgrade the contract (non-upgradeable, immutable logic).
/// @dev Anti-cheat (disclosed honestly): run results are player-attested with a run hash.
///      A team completion only counts on-chain when all 5 roster members submit the same
///      runHash. The contract is a record/identity layer, not a referee.
interface IAgentId {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
}

contract CrumbleArena {
    IAgentId public immutable agentId;

    uint8 public constant NUM_LEVELS = 6;
    uint8 public constant NUM_CLASSES = 3;
    uint8 public constant MAX_TEAM = 5;
    uint8 public constant FULL_TEAM = 5;
    uint8 public constant NUM_QUESTS = 3;
    uint8 public constant MAX_LEVEL = 10;

    /// @notice Base XP per level completion (index = levelId - 1).
    uint32[6] public levelBaseXp = [100, 150, 200, 250, 300, 400];
    /// @notice Par time per level in ms; finishing faster earns a time bonus (max +50 XP).
    uint32[6] public levelParMs = [120_000, 150_000, 180_000, 210_000, 240_000, 300_000];
    /// @notice XP awarded per daily quest completion.
    uint32 public constant QUEST_XP = 25;
    /// @notice Max time bonus XP for beating par time.
    uint32 public constant MAX_TIME_BONUS = 50;

    /// @notice Badge bits stored in Player.badges.
    uint8 public constant BADGE_FIRST_RUN = 1 << 0;
    uint8 public constant BADGE_TEAM_PLAYER = 1 << 1; // part of a 5/5 team completion
    uint8 public constant BADGE_STREAK_3 = 1 << 2; // 3-day quest streak
    uint8 public constant BADGE_VETERAN = 1 << 3; // 10 runs completed

    address public owner;
    bool public paused;
    uint256 public season = 1;

    struct Player {
        uint256 tokenId;
        uint8 classId;
        uint32 xp;
        uint32 runs;
        uint32 questsCompleted;
        uint32 questStreak;
        uint32 lastQuestDay;
        uint8 badges;
        uint32[6] bestTimesMs; // 0 = level not completed yet
    }

    mapping(uint256 => Player) private _players;
    mapping(uint256 => bool) private _registered;
    mapping(address => uint256) private _tokenIdOf;
    mapping(bytes32 => mapping(uint256 => bool)) private _hasAttested;
    mapping(bytes32 => uint8) private _attestationCount;
    mapping(bytes32 => bytes32) private _runRosterHash;
    mapping(bytes32 => uint8) private _runLevel;
    mapping(uint256 => mapping(uint8 => uint32)) private _lastQuestDay; // tokenId => questId => day

    event PlayerRegistered(uint256 indexed tokenId, address indexed player, uint8 classId);
    event RunCompleted(
        uint256 indexed tokenId,
        address indexed player,
        uint8 levelId,
        uint32 timeMs,
        uint32 xpGained,
        uint8 newLevel,
        bytes32 runHash,
        uint8 teamSize
    );
    event TeamRunComplete(bytes32 indexed runHash, uint8 levelId, uint256[] teamTokenIds, uint32 timeMs);
    event QuestCompleted(
        uint256 indexed tokenId,
        address indexed player,
        uint8 questId,
        uint32 day,
        uint32 streak,
        uint32 xpGained,
        bytes32 proofHash
    );
    event SeasonStarted(uint256 indexed season);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotAgentIdHolder();
    error AlreadyRegistered();
    error NotRegistered();
    error InvalidClass();
    error InvalidLevel();
    error InvalidQuest();
    error InvalidTime();
    error EmptyTeam();
    error TeamTooLarge();
    error NotInTeam();
    error DuplicateTeammate();
    error TeammateNotRegistered();
    error AlreadyAttested();
    error RosterMismatch();
    error LevelMismatch();
    error QuestAlreadyDoneToday();
    error PausedContract();
    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedContract();
        _;
    }

    /// @dev The owner is set explicitly at deploy time (not msg.sender) so the
    ///      contract can be deployed through a deterministic CREATE2 factory
    ///      while the owner stays the project wallet (danzz.ai).
    constructor(address _agentId, address _owner) {
        if (_agentId == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        agentId = IAgentId(_agentId);
        owner = _owner;
    }

    /// @notice Register a fighter. One profile per Agent ID tokenId, one tokenId per address.
    /// @dev Verifies agentId.ownerOf(tokenId) == msg.sender — the Agent ID gate.
    function registerPlayer(uint256 tokenId, uint8 classId) external whenNotPaused {
        if (classId >= NUM_CLASSES) revert InvalidClass();
        if (_registered[tokenId]) revert AlreadyRegistered();
        if (_tokenIdOf[msg.sender] != 0) revert AlreadyRegistered();
        if (agentId.ownerOf(tokenId) != msg.sender) revert NotAgentIdHolder();

        _registered[tokenId] = true;
        _tokenIdOf[msg.sender] = tokenId;
        Player storage p = _players[tokenId];
        p.tokenId = tokenId;
        p.classId = classId;

        emit PlayerRegistered(tokenId, msg.sender, classId);
    }

    /// @notice Record a completed level run. Each roster member submits their own attestation.
    /// @dev The roster order is part of the run identity: all attestations of one run must
    ///      submit the exact same teamTokenIds array (same order) and the same levelId.
    ///      A team completion counts on-chain only when all 5 roster members attest the
    ///      same runHash (TeamRunComplete at 5/5). Solo / smaller teams record individual
    ///      completions only.
    function submitRun(uint8 levelId, bytes32 runHash, uint256[] calldata teamTokenIds, uint32 timeMs)
        external
        whenNotPaused
    {
        if (levelId < 1 || levelId > NUM_LEVELS) revert InvalidLevel();
        if (timeMs == 0) revert InvalidTime();
        if (teamTokenIds.length == 0) revert EmptyTeam();
        if (teamTokenIds.length > MAX_TEAM) revert TeamTooLarge();

        uint256 myTokenId = _tokenIdOf[msg.sender];
        if (myTokenId == 0) revert NotRegistered();
        if (_hasAttested[runHash][myTokenId]) revert AlreadyAttested();

        _validateRoster(teamTokenIds, myTokenId);

        bytes32 rosterHash = keccak256(abi.encode(teamTokenIds));
        if (_attestationCount[runHash] == 0) {
            _runRosterHash[runHash] = rosterHash;
            _runLevel[runHash] = levelId;
        } else {
            if (_runRosterHash[runHash] != rosterHash) revert RosterMismatch();
            if (_runLevel[runHash] != levelId) revert LevelMismatch();
        }
        _hasAttested[runHash][myTokenId] = true;
        _attestationCount[runHash] += 1;

        uint32 xpGained = _runXp(levelId, timeMs);

        Player storage p = _players[myTokenId];
        p.xp += xpGained;
        p.runs += 1;
        if (p.bestTimesMs[levelId - 1] == 0 || timeMs < p.bestTimesMs[levelId - 1]) {
            p.bestTimesMs[levelId - 1] = timeMs;
        }
        p.badges |= BADGE_FIRST_RUN;
        if (p.runs >= 10) p.badges |= BADGE_VETERAN;
        uint8 newLevel = levelForXp(p.xp);

        emit RunCompleted(
            myTokenId, msg.sender, levelId, timeMs, xpGained, newLevel, runHash, uint8(teamTokenIds.length)
        );

        // Full 5-agent team, all 5 attested: the team completion is real on-chain.
        if (teamTokenIds.length == FULL_TEAM && _attestationCount[runHash] == FULL_TEAM) {
            for (uint256 i = 0; i < teamTokenIds.length; i++) {
                _players[teamTokenIds[i]].badges |= BADGE_TEAM_PLAYER;
            }
            emit TeamRunComplete(runHash, levelId, teamTokenIds, timeMs);
        }
    }

    /// @dev Validates a run roster: sender is in it, everyone is registered, no duplicates.
    function _validateRoster(uint256[] calldata teamTokenIds, uint256 myTokenId) internal view {
        bool inTeam = false;
        for (uint256 i = 0; i < teamTokenIds.length; i++) {
            if (teamTokenIds[i] == myTokenId) inTeam = true;
            if (!_registered[teamTokenIds[i]]) revert TeammateNotRegistered();
            for (uint256 j = i + 1; j < teamTokenIds.length; j++) {
                if (teamTokenIds[i] == teamTokenIds[j]) revert DuplicateTeammate();
            }
        }
        if (!inTeam) revert NotInTeam();
    }

    /// @dev XP for a run: level base XP + time bonus (max +50) for beating par time.
    function _runXp(uint8 levelId, uint32 timeMs) internal view returns (uint32) {
        uint32 xpGained = levelBaseXp[levelId - 1];
        uint32 par = levelParMs[levelId - 1];
        if (timeMs < par) {
            uint32 bonus = (par - timeMs) / 1000;
            if (bonus > MAX_TIME_BONUS) bonus = MAX_TIME_BONUS;
            xpGained += bonus;
        }
        return xpGained;
    }

    /// @notice Record a daily quest completion. Once per day per quest per player.
    /// @dev Quest semantics (which quest, what counts) are defined by the game; the
    ///      proofHash commits to the off-chain quest evidence. Player-attested, as disclosed.
    function submitDailyQuest(uint8 questId, bytes32 proofHash) external whenNotPaused {
        if (questId >= NUM_QUESTS) revert InvalidQuest();
        uint256 myTokenId = _tokenIdOf[msg.sender];
        if (myTokenId == 0) revert NotRegistered();

        uint32 day = uint32(block.timestamp / 1 days);
        if (_lastQuestDay[myTokenId][questId] == day) revert QuestAlreadyDoneToday();

        Player storage p = _players[myTokenId];
        uint32 prevDay = p.lastQuestDay;
        if (prevDay != 0 && prevDay == day) {
            // Already did a (different) quest today: streak unchanged.
        } else if (prevDay + 1 == day) {
            p.questStreak += 1;
        } else {
            p.questStreak = 1;
        }
        p.lastQuestDay = day;
        _lastQuestDay[myTokenId][questId] = day;
        p.questsCompleted += 1;
        p.xp += QUEST_XP;
        if (p.questStreak >= 3) p.badges |= BADGE_STREAK_3;

        emit QuestCompleted(myTokenId, msg.sender, questId, day, p.questStreak, QUEST_XP, proofHash);
    }

    // ---- Views ----

    /// @notice Level for a given XP total. Thresholds: L1 0, L2 100, L3 250, L4 500,
    ///         L5 900, L6 1500, L7 2500, L8 4000, L9 6500, L10 10000.
    function levelForXp(uint32 xp) public pure returns (uint8) {
        if (xp >= 10_000) return 10;
        if (xp >= 6_500) return 9;
        if (xp >= 4_000) return 8;
        if (xp >= 2_500) return 7;
        if (xp >= 1_500) return 6;
        if (xp >= 900) return 5;
        if (xp >= 500) return 4;
        if (xp >= 250) return 3;
        if (xp >= 100) return 2;
        return 1;
    }

    function getPlayer(uint256 tokenId)
        external
        view
        returns (
            uint8 classId,
            uint8 level,
            uint32 xp,
            uint32 runs,
            uint32 questsCompleted,
            uint32 questStreak,
            uint8 badges,
            uint32[6] memory bestTimesMs
        )
    {
        if (!_registered[tokenId]) revert NotRegistered();
        Player storage p = _players[tokenId];
        return (
            p.classId,
            levelForXp(p.xp),
            p.xp,
            p.runs,
            p.questsCompleted,
            p.questStreak,
            p.badges,
            p.bestTimesMs
        );
    }

    function getPlayerByAddress(address player)
        external
        view
        returns (
            uint256 tokenId,
            uint8 classId,
            uint8 level,
            uint32 xp,
            uint32 runs,
            uint32 questsCompleted,
            uint32 questStreak,
            uint8 badges,
            uint32[6] memory bestTimesMs
        )
    {
        uint256 tid = _tokenIdOf[player];
        if (tid == 0) revert NotRegistered();
        Player storage p = _players[tid];
        return (
            tid,
            p.classId,
            levelForXp(p.xp),
            p.xp,
            p.runs,
            p.questsCompleted,
            p.questStreak,
            p.badges,
            p.bestTimesMs
        );
    }

    function isRegistered(address player) external view returns (bool) {
        return _tokenIdOf[player] != 0;
    }

    function tokenIdOf(address player) external view returns (uint256) {
        return _tokenIdOf[player];
    }

    function getRunAttestations(bytes32 runHash)
        external
        view
        returns (uint8 count, bytes32 rosterHash, uint8 levelId)
    {
        return (_attestationCount[runHash], _runRosterHash[runHash], _runLevel[runHash]);
    }

    function hasAttested(bytes32 runHash, uint256 tokenId) external view returns (bool) {
        return _hasAttested[runHash][tokenId];
    }

    /// @notice Resolve a player's `.ai` handle on-chain via the Agent ID contract.
    function playerHandle(address player) external view returns (string memory) {
        return agentId.handleOf(player);
    }

    // ---- Owner (disclosed powers only: pause + season epoch + ownership transfer) ----

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Start a new season. Only the leaderboard epoch changes; XP history is untouched.
    function startSeason() external onlyOwner {
        season += 1;
        emit SeasonStarted(season);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
