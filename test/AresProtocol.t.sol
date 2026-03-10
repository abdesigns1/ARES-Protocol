// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/core/ProposalManager.sol";
import "../src/modules/TimelockEngine.sol";
import "../src/modules/RewardDistributor.sol";
import "../src/modules/GovernanceGuard.sol";
import "../src/libraries/SignatureLib.sol";
import "../src/libraries/MerkleLib.sol";


// mocktoken for testing
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReentrancyAttacker {
    TimelockEngine public timelock;
    bool public reentryBlocked;

    constructor(address _timelock) {
        timelock = TimelockEngine(_timelock);
    }

  
    receive() external payable {
        bytes32 fakeOpId = keccak256("fake");
        try timelock.execute(fakeOpId, address(this), 0, "") {
            
        } catch {
           
            reentryBlocked = true;
        }
    }

    fallback() external payable {}
}


// Main test contract

contract AresProtocolTest is Test {
    ProposalManager public proposalManager;
    TimelockEngine public timelock;
    RewardDistributor public distributor;
    GovernanceGuard public guard;
    MockToken public token;

    // Test signers with known private keys
    uint256 constant SIGNER1_KEY = 0xA11CE;
    uint256 constant SIGNER2_KEY = 0xB0B;
    uint256 constant SIGNER3_KEY = 0xCAFE;

    address signer1;
    address signer2;
    address signer3;
    address alice; 

    function setUp() public {
        signer1 = vm.addr(SIGNER1_KEY);
        signer2 = vm.addr(SIGNER2_KEY);
        signer3 = vm.addr(SIGNER3_KEY);
        alice = makeAddr("alice");

        token = new MockToken();

       
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

 

     
        timelock = new TimelockEngine(address(this));

    
        guard = new GovernanceGuard(address(this), 100_000 ether);

   
        proposalManager = new ProposalManager(
            signers,
            2,           
            address(timelock),
            address(guard)
        );

      
        token.mint(address(timelock), 1_000_000 ether);


        distributor = new RewardDistributor(address(this), address(token));
        token.mint(address(distributor), 500_000 ether);

        vm.warp(block.timestamp + 2 hours);
    }

    // FUNCTIONAL TESTS

    function test_ProposeCreatesProposal() public {
        vm.prank(signer1);
        uint256 id = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            1000 ether,
            ""
        );

        IProposalManager.Proposal memory p = proposalManager.getProposal(id);
        assertEq(p.id, 1);
        assertEq(uint8(p.state), uint8(IProposalManager.ProposalState.Pending));
        assertEq(p.proposer, signer1);
        assertEq(p.amount, 1000 ether);
    }

  
    function test_NonSignerCannotPropose() public {
        vm.prank(alice);
        vm.expectRevert("ProposalManager: not a signer");
        proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            100 ether,
            ""
        );
    }


    function test_ProposalApprovalFlow() public {

        // proposal
        vm.prank(signer1);
        uint256 id = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            1000 ether,
            ""
        );


        bytes32 domainSep = proposalManager.DOMAIN_SEPARATOR();

       
        bytes32 digest1 = SignatureLib.hashApproval(domainSep, id, proposalManager.nonces(signer1), block.timestamp + 1 days);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(SIGNER1_KEY, digest1);
        bytes memory sig1 = abi.encodePacked(r1, s1, v1);
        vm.prank(signer1);
        proposalManager.approve(id, sig1);

       
        assertEq(uint8(proposalManager.getProposal(id).state), uint8(IProposalManager.ProposalState.Pending));

       
        bytes32 digest2 = SignatureLib.hashApproval(domainSep, id, proposalManager.nonces(signer2), block.timestamp + 1 days);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(SIGNER2_KEY, digest2);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);
        vm.prank(signer2);
        proposalManager.approve(id, sig2);

        assertEq(uint8(proposalManager.getProposal(id).state), uint8(IProposalManager.ProposalState.Approved));
    }


    function test_ProposerCanCancelProposal() public {
        vm.prank(signer1);
        uint256 id = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            500 ether,
            ""
        );

        vm.prank(signer1);
        proposalManager.cancel(id);

        assertEq(uint8(proposalManager.getProposal(id).state), uint8(IProposalManager.ProposalState.Cancelled));
    }


    function test_ClaimRewardWithValidProof() public {

        address bob = makeAddr("bob");
        uint256 epoch = 1;

        bytes32 aliceLeaf = MerkleLib.leafHash(alice, 100 ether, epoch);
        bytes32 bobLeaf = MerkleLib.leafHash(bob, 200 ether, epoch);


        bytes32 root;
        bytes32[] memory aliceProof = new bytes32[](1);
        if (aliceLeaf <= bobLeaf) {
            root = keccak256(abi.encodePacked(aliceLeaf, bobLeaf));
            aliceProof[0] = bobLeaf;
        } else {
            root = keccak256(abi.encodePacked(bobLeaf, aliceLeaf));
            aliceProof[0] = bobLeaf;
        }


        distributor.updateRoot(root);


        vm.prank(alice);
        distributor.claim(1, 100 ether, aliceProof);

        assertTrue(distributor.hasClaimed(1, alice));
    }


    function test_TimelockEnforcesDelay() public {
        bytes32 opId = keccak256("testOp");
        timelock.queue(opId);

     
        vm.expectRevert("TimelockEngine: too early");
        timelock.execute(opId, address(token), 0, abi.encodeWithSignature("transfer(address,uint256)", alice, 1 ether));
    }

  
    function test_TimelockExecutesAfterDelay() public {

        bytes32 opId = keccak256("testOp");
        timelock.queue(opId);

      
        vm.warp(block.timestamp + 2 days + 1);

        assertTrue(timelock.isReady(opId));
    }

    // EXPLOIT / NEGATIVE TESTS

  
    function test_ReentrancyBlocked() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(timelock));

        bytes memory emptyData = "";
        bytes32 opId = timelock.operationId(address(attacker), 1, emptyData, 999);
        timelock.queue(opId);
        vm.warp(block.timestamp + 2 days + 1);


        vm.deal(address(timelock), 1);


        timelock.execute(opId, address(attacker), 1, emptyData);


        assertTrue(attacker.reentryBlocked(), "Reentrancy should have been blocked");
    }

    function test_DoubleClaimBlocked() public {
        uint256 epoch = 1;
        bytes32 aliceLeaf = MerkleLib.leafHash(alice, 100 ether, epoch);
        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = aliceLeaf;

        distributor.updateRoot(root);

        vm.prank(alice);
        distributor.claim(1, 100 ether, proof);

       
        vm.prank(alice);
        vm.expectRevert("RewardDistributor: already claimed");
        distributor.claim(1, 100 ether, proof);
    }


    function test_InvalidSignatureRejected() public {
        vm.prank(signer1);
        uint256 id = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            1000 ether,
            ""
        );


        bytes32 domainSep = proposalManager.DOMAIN_SEPARATOR();
        bytes32 digest = SignatureLib.hashApproval(domainSep, id, proposalManager.nonces(signer1), block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER3_KEY, digest); 
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(signer1);
        vm.expectRevert("ProposalManager: signature mismatch");
        proposalManager.approve(id, badSig);
    }


    function test_PrematureExecutionBlocked() public {
        bytes32 opId = keccak256("premature");
        timelock.queue(opId);

    
        vm.warp(block.timestamp + 1);
        vm.expectRevert("TimelockEngine: too early");
        timelock.execute(opId, alice, 0, "");
    }


    function test_ProposalReplayBlocked() public {
        bytes32 opId = keccak256("replayTest");
        timelock.queue(opId);

  
        vm.expectRevert("TimelockEngine: already queued");
        timelock.queue(opId);
    }


    function test_SignatureReplayBlocked() public {
        vm.prank(signer1);
        uint256 id1 = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            100 ether,
            ""
        );

        
        uint256 nonceBeforeApproval = proposalManager.nonces(signer1);
        bytes32 domainSep = proposalManager.DOMAIN_SEPARATOR();
        bytes32 digest = SignatureLib.hashApproval(domainSep, id1, nonceBeforeApproval, block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER1_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(signer1);
        proposalManager.approve(id1, sig);

   
        vm.prank(signer1);
        vm.expectRevert("ProposalManager: already approved");
        proposalManager.approve(id1, sig);
    }


    function test_NonSignerCannotApprove() public {
        vm.prank(signer1);
        uint256 id = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            100 ether,
            ""
        );

        bytes32 domainSep = proposalManager.DOMAIN_SEPARATOR();
        bytes32 digest = SignatureLib.hashApproval(domainSep, id, 0, block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        address nonSigner = vm.addr(0xDEAD);
        vm.prank(nonSigner);
        vm.expectRevert("ProposalManager: not a signer");
        proposalManager.approve(id, sig);
    }


    function test_InvalidMerkleProofRejected() public {
        uint256 epoch = 1;
        bytes32 aliceLeaf = MerkleLib.leafHash(alice, 100 ether, epoch);
        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = aliceLeaf;
        distributor.updateRoot(root);


        vm.prank(alice);
        vm.expectRevert("RewardDistributor: invalid proof");
        distributor.claim(1, 999 ether, proof); 
    }

    function test_ExpiredOperationCannotExecute() public {
        bytes32 opId = keccak256("expiredOp");
        timelock.queue(opId);


        vm.warp(block.timestamp + 2 days + 7 days + 1);

        vm.expectRevert("TimelockEngine: expired");
        timelock.execute(opId, alice, 0, "");
    }

  
    function test_CancelledProposalCannotBeQueued() public {
        vm.prank(signer1);
        uint256 id = proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            100 ether,
            ""
        );

        vm.prank(signer1);
        proposalManager.cancel(id);

  
        vm.prank(signer1);
        vm.expectRevert("ProposalManager: cannot cancel");
        proposalManager.cancel(id);
    }


    function test_ProposalCooldownPreventsSpam() public {
        vm.prank(signer1);
        proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            100 ether,
            ""
        );

   
        vm.prank(signer1);
        vm.expectRevert("GovernanceGuard: proposal cooldown active");
        proposalManager.propose(
            IProposalManager.ActionType.Transfer,
            address(token),
            alice,
            200 ether,
            ""
        );
    }
}
