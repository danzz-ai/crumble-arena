// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/CrumbleArena.sol";
import "./MockAgentId.sol";

contract CrumbleArenaTest is Test {
    CrumbleArena public arena;
    MockAgentId public agentId;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public dave = makeAddr("dave");
    address public erin = makeAddr("erin");
    address public mallory = makeAddr("mallory"); // no Agent ID

    uint256 public aliceId;
    uint256 public bobId;
    uint256 public carolId;
    uint256 public daveId;
    uint256 public erinId;

    function setUp() public {
        // Realistic chain time (Nov 2026) so "day" numbers behave like mainnet.
        vm.warp(1_795_000_000);
        agentId = new MockAgentId();
        arena = new CrumbleArena(address(agentId), address(this));

        aliceId = uint256(keccak256(abi.encodePacked("alice")));
        bobId = uint256(keccak256(abi.encodePacked("bob")));
        carolId = uint256(keccak256(abi.encodePacked("carol")));
        daveId = uint256(keccak256(abi.encodePacked("dave")));
        erinId = uint256(keccak256(abi.encodePacked("erin")));

        agentId.mint(alice, aliceId, "alice");
        agentId.mint(bob, bobId, "bob");
        agentId.mint(carol, carolId, "carol");
        agentId.mint(dave, daveId, "dave");
        agentId.mint(erin, erinId, "erin");
    }

    function _team() internal view returns (uint256[] memory) {
        uint256[] memory team = new uint256[](5);
        team[0] = aliceId;
        team[1] = bobId;
        team[2] = carolId;
        team[3] = daveId;
        team[4] = erinId;
        return team;
    }

    function _registerAll() internal {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        vm.prank(bob);
        arena.registerPlayer(bobId, 1);
        vm.prank(carol);
        arena.registerPlayer(carolId, 2);
        vm.prank(dave);
        arena.registerPlayer(daveId, 0);
        vm.prank(erin);
        arena.registerPlayer(erinId, 1);
    }

    function _runHash(uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("run", nonce));
    }

    // ---- Registration ----

    function testRegisterSuccess() public {
        vm.expectEmit(true, true, false, true);
        emit CrumbleArena.PlayerRegistered(aliceId, alice, 1);
        vm.prank(alice);
        arena.registerPlayer(aliceId, 1);

        assertTrue(arena.isRegistered(alice));
        assertEq(arena.tokenIdOf(alice), aliceId);
        (uint8 classId, uint8 level, uint32 xp, uint32 runs,,,,) = arena.getPlayer(aliceId);
        assertEq(classId, 1);
        assertEq(level, 1);
        assertEq(xp, 0);
        assertEq(runs, 0);
        assertEq(arena.playerHandle(alice), "alice");
    }

    function testRegisterRevertsForNonHolder() public {
        vm.prank(bob);
        vm.expectRevert(CrumbleArena.NotAgentIdHolder.selector);
        arena.registerPlayer(aliceId, 0);
    }

    function testRegisterRevertsNonexistentToken() public {
        uint256 ghost = uint256(keccak256(abi.encodePacked("ghost")));
        vm.prank(mallory);
        vm.expectRevert(); // mock ownerOf reverts (mirrors the real contract)
        arena.registerPlayer(ghost, 0);
    }

    function testRegisterRevertsDouble() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.AlreadyRegistered.selector);
        arena.registerPlayer(aliceId, 0);
    }

    function testRegisterRevertsSecondTokenSameAddress() public {
        uint256 aliceId2 = uint256(keccak256(abi.encodePacked("alice2")));
        agentId.mint(alice, aliceId2, "alice2");
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.AlreadyRegistered.selector);
        arena.registerPlayer(aliceId2, 0);
    }

    function testRegisterRevertsInvalidClass() public {
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.InvalidClass.selector);
        arena.registerPlayer(aliceId, 3);
    }

    function testRegisterRevertsNoAgentId() public {
        // mallory holds no Agent ID at all; any tokenId she tries is not hers.
        vm.prank(mallory);
        vm.expectRevert(CrumbleArena.NotAgentIdHolder.selector);
        arena.registerPlayer(aliceId, 0);
    }

    // ---- Runs ----

    function testSubmitRunSolo() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        bytes32 h = _runHash(1);

        vm.prank(alice);
        arena.submitRun(1, h, team, 60_000);

        // Level 1 base 100 + time bonus min((120000-60000)/1000, 50) = 150 XP.
        (, uint8 level, uint32 xp, uint32 runs,,,, uint32[6] memory best) = arena.getPlayer(aliceId);
        assertEq(xp, 150);
        assertEq(level, 2); // 150 XP >= 100 threshold
        assertEq(runs, 1);
        assertEq(best[0], 60_000);
        (uint8 count,,) = arena.getRunAttestations(h);
        assertEq(count, 1);
        assertTrue(arena.hasAttested(h, aliceId));
    }

    function testSubmitRunNoTimeBonusWhenSlow() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        vm.prank(alice);
        arena.submitRun(1, _runHash(2), team, 130_000); // slower than par 120_000
        (,, uint32 xp,,,,,) = arena.getPlayer(aliceId);
        assertEq(xp, 100); // base only
    }

    function testSubmitRunBestTimeUpdates() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        vm.startPrank(alice);
        arena.submitRun(1, _runHash(3), team, 90_000);
        arena.submitRun(1, _runHash(4), team, 95_000); // slower: best stays 90_000
        arena.submitRun(1, _runHash(5), team, 80_000); // faster: best becomes 80_000
        vm.stopPrank();
        (,,,,,,, uint32[6] memory best) = arena.getPlayer(aliceId);
        assertEq(best[0], 80_000);
    }

    function testSubmitRunRevertsNotRegistered() public {
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.NotRegistered.selector);
        arena.submitRun(1, _runHash(6), team, 60_000);
    }

    function testSubmitRunRevertsNotInTeam() public {
        _registerAll();
        uint256[] memory team = new uint256[](1);
        team[0] = bobId; // alice not in the roster
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.NotInTeam.selector);
        arena.submitRun(1, _runHash(7), team, 60_000);
    }

    function testSubmitRunRevertsTeammateNotRegistered() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256 ghost = uint256(keccak256(abi.encodePacked("ghost2")));
        uint256[] memory team = new uint256[](2);
        team[0] = aliceId;
        team[1] = ghost;
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.TeammateNotRegistered.selector);
        arena.submitRun(1, _runHash(8), team, 60_000);
    }

    function testSubmitRunRevertsDuplicateTeammate() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256[] memory team = new uint256[](2);
        team[0] = aliceId;
        team[1] = aliceId;
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.DuplicateTeammate.selector);
        arena.submitRun(1, _runHash(9), team, 60_000);
    }

    function testSubmitRunRevertsDuplicateAttestation() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        bytes32 h = _runHash(10);
        vm.startPrank(alice);
        arena.submitRun(1, h, team, 60_000);
        vm.expectRevert(CrumbleArena.AlreadyAttested.selector);
        arena.submitRun(1, h, team, 60_000);
        vm.stopPrank();
    }

    function testSubmitRunRevertsBadArgs() public {
        _registerAll();
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        vm.startPrank(alice);
        vm.expectRevert(CrumbleArena.InvalidLevel.selector);
        arena.submitRun(0, _runHash(11), team, 60_000);
        vm.expectRevert(CrumbleArena.InvalidLevel.selector);
        arena.submitRun(7, _runHash(12), team, 60_000);
        vm.expectRevert(CrumbleArena.InvalidTime.selector);
        arena.submitRun(1, _runHash(13), team, 0);
        vm.expectRevert(CrumbleArena.EmptyTeam.selector);
        arena.submitRun(1, _runHash(14), new uint256[](0), 60_000);
        uint256[] memory big = new uint256[](6);
        big[0] = aliceId;
        big[1] = bobId;
        big[2] = carolId;
        big[3] = daveId;
        big[4] = erinId;
        big[5] = aliceId;
        vm.expectRevert(CrumbleArena.TeamTooLarge.selector);
        arena.submitRun(1, _runHash(15), big, 60_000);
        vm.stopPrank();
    }

    function testTeamRunComplete() public {
        _registerAll();
        uint256[] memory team = _team();
        bytes32 h = _runHash(20);

        address[5] memory players = [alice, bob, carol, dave, erin];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(players[i]);
            arena.submitRun(2, h, team, 100_000);
        }
        (uint8 count,,) = arena.getRunAttestations(h);
        assertEq(count, 4);

        // 5th attestation completes the team run.
        vm.expectEmit(true, false, false, true);
        emit CrumbleArena.TeamRunComplete(h, 2, team, 100_000);
        vm.prank(erin);
        arena.submitRun(2, h, team, 100_000);

        (count,,) = arena.getRunAttestations(h);
        assertEq(count, 5);
        // Every roster member earned the TEAM_PLAYER badge.
        uint256[5] memory ids = [aliceId, bobId, carolId, daveId, erinId];
        for (uint256 i = 0; i < 5; i++) {
            (,,,,,, uint8 badges,) = arena.getPlayer(ids[i]);
            assertTrue(badges & arena.BADGE_TEAM_PLAYER() != 0);
        }
    }

    function testTeamRunRevertsRosterMismatch() public {
        _registerAll();
        uint256[] memory team = _team();
        bytes32 h = _runHash(21);
        address[5] memory players = [alice, bob, carol, dave, erin];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(players[i]);
            arena.submitRun(1, h, team, 90_000);
        }
        // Erin submits the same team in reversed order: different roster hash.
        uint256[] memory reversed = new uint256[](5);
        reversed[0] = erinId;
        reversed[1] = daveId;
        reversed[2] = carolId;
        reversed[3] = bobId;
        reversed[4] = aliceId;
        vm.prank(erin);
        vm.expectRevert(CrumbleArena.RosterMismatch.selector);
        arena.submitRun(1, h, reversed, 90_000);
    }

    function testTeamRunRevertsLevelMismatch() public {
        _registerAll();
        uint256[] memory team = _team();
        bytes32 h = _runHash(22);
        address[5] memory players = [alice, bob, carol, dave, erin];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(players[i]);
            arena.submitRun(1, h, team, 90_000);
        }
        vm.prank(erin);
        vm.expectRevert(CrumbleArena.LevelMismatch.selector);
        arena.submitRun(2, h, team, 90_000);
    }

    function testVeteranBadge() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        uint256[] memory team = new uint256[](1);
        team[0] = aliceId;
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            arena.submitRun(1, _runHash(100 + i), team, 100_000);
        }
        vm.stopPrank();
        (,,,,,, uint8 badges,) = arena.getPlayer(aliceId);
        assertTrue(badges & arena.BADGE_VETERAN() != 0);
        assertTrue(badges & arena.BADGE_FIRST_RUN() != 0);
    }

    // ---- Daily quests ----

    function testDailyQuest() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);

        vm.prank(alice);
        arena.submitDailyQuest(0, keccak256("proof-1"));
        (,, uint32 xp,, uint32 quests, uint32 streak,,) = arena.getPlayer(aliceId);
        assertEq(xp, 25);
        assertEq(quests, 1);
        assertEq(streak, 1);

        // Same quest, same day: revert.
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.QuestAlreadyDoneToday.selector);
        arena.submitDailyQuest(0, keccak256("proof-2"));

        // Different quest, same day: allowed, streak unchanged.
        vm.prank(alice);
        arena.submitDailyQuest(1, keccak256("proof-3"));
        (,,,, uint32 quests2, uint32 streak2,,) = arena.getPlayer(aliceId);
        assertEq(quests2, 2);
        assertEq(streak2, 1);

        // Next day: quest 0 again, streak becomes 2.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        arena.submitDailyQuest(0, keccak256("proof-4"));
        (,,,,, uint32 streak3,,) = arena.getPlayer(aliceId);
        assertEq(streak3, 2);

        // Third consecutive day: streak 3 -> STREAK_3 badge.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        arena.submitDailyQuest(0, keccak256("proof-5"));
        (,,,,,, uint8 badges,) = arena.getPlayer(aliceId);
        assertTrue(badges & arena.BADGE_STREAK_3() != 0);

        // Skip a day: streak resets to 1.
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        arena.submitDailyQuest(0, keccak256("proof-6"));
        (,,,,, uint32 streak4,,) = arena.getPlayer(aliceId);
        assertEq(streak4, 1);
    }

    function testDailyQuestReverts() public {
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.InvalidQuest.selector);
        arena.submitDailyQuest(3, keccak256("x"));

        vm.prank(mallory);
        vm.expectRevert(CrumbleArena.NotRegistered.selector);
        arena.submitDailyQuest(0, keccak256("x"));
    }

    // ---- Owner / pause / season ----

    function testPause() public {
        arena.pause();
        assertTrue(arena.paused());
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.PausedContract.selector);
        arena.registerPlayer(aliceId, 0);
        arena.unpause();
        assertFalse(arena.paused());
        vm.prank(alice);
        arena.registerPlayer(aliceId, 0);
        assertTrue(arena.isRegistered(alice));
    }

    function testPauseOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.NotOwner.selector);
        arena.pause();
    }

    function testSeason() public {
        assertEq(arena.season(), 1);
        vm.expectEmit(true, false, false, true);
        emit CrumbleArena.SeasonStarted(2);
        arena.startSeason();
        assertEq(arena.season(), 2);
        vm.prank(alice);
        vm.expectRevert(CrumbleArena.NotOwner.selector);
        arena.startSeason();
    }

    function testTransferOwnership() public {
        arena.transferOwnership(bob);
        assertEq(arena.owner(), bob);
        vm.prank(bob);
        arena.pause();
        assertTrue(arena.paused());
    }

    function testOwnerSetAtDeploy() public view {
        assertEq(arena.owner(), address(this));
    }

    function testConstructorRevertsZeroOwner() public {
        vm.expectRevert(CrumbleArena.ZeroAddress.selector);
        new CrumbleArena(address(agentId), address(0));
    }

    function testConstructorRevertsZeroAgentId() public {
        vm.expectRevert(CrumbleArena.ZeroAddress.selector);
        new CrumbleArena(address(0), address(this));
    }

    // ---- Views / level curve ----

    function testLevelCurve() public view {
        assertEq(arena.levelForXp(0), 1);
        assertEq(arena.levelForXp(99), 1);
        assertEq(arena.levelForXp(100), 2);
        assertEq(arena.levelForXp(249), 2);
        assertEq(arena.levelForXp(250), 3);
        assertEq(arena.levelForXp(500), 4);
        assertEq(arena.levelForXp(900), 5);
        assertEq(arena.levelForXp(1500), 6);
        assertEq(arena.levelForXp(2500), 7);
        assertEq(arena.levelForXp(4000), 8);
        assertEq(arena.levelForXp(6500), 9);
        assertEq(arena.levelForXp(9999), 9);
        assertEq(arena.levelForXp(10000), 10);
        assertEq(arena.levelForXp(1_000_000), 10);
    }

    function testViews() public {
        _registerAll();
        (uint256 tid, uint8 classId,,,,,,,) = arena.getPlayerByAddress(bob);
        assertEq(tid, bobId);
        assertEq(classId, 1);
        assertEq(arena.playerHandle(carol), "carol");
        assertEq(arena.playerHandle(mallory), "");
        vm.prank(mallory);
        vm.expectRevert(CrumbleArena.NotRegistered.selector);
        arena.getPlayerByAddress(mallory);
    }
}
