// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/core/ProposalManager.sol";
import "../src/modules/TimelockEngine.sol";
import "../src/modules/RewardDistributor.sol";
import "../src/modules/GovernanceGuard.sol";

/// @notice Deployment script for the ARES Protocol treasury system.
///         Run with: forge script script/Deploy.s.sol --broadcast
contract Deploy is Script {
    function run() external {
        // Load signers from environment variables
        address signer1 = vm.envAddress("SIGNER1");
        address signer2 = vm.envAddress("SIGNER2");
        address signer3 = vm.envAddress("SIGNER3");
        address rewardToken = vm.envAddress("REWARD_TOKEN");

        // Daily drain limit: 50,000 tokens
        uint256 dailyLimit = 50_000 ether;

        vm.startBroadcast();

        // Step 1: Deploy a temporary timelock (governance = deployer)
        // In production, use CREATE2 to predetermine ProposalManager address
        // and deploy timelock pointing directly to it.
        TimelockEngine timelock = new TimelockEngine(msg.sender);
        console.log("TimelockEngine deployed at:", address(timelock));

        // Step 2: Deploy GovernanceGuard
        GovernanceGuard guard = new GovernanceGuard(msg.sender, dailyLimit);
        console.log("GovernanceGuard deployed at:", address(guard));

        // Step 3: Deploy ProposalManager with 2-of-3 signers
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        ProposalManager proposalManager = new ProposalManager(
            signers,
            2, // 2-of-3 threshold
            address(timelock),
            address(guard)
        );
        console.log("ProposalManager deployed at:", address(proposalManager));

        // Step 4: Deploy RewardDistributor
        RewardDistributor distributor = new RewardDistributor(
            address(proposalManager),
            rewardToken
        );
        console.log("RewardDistributor deployed at:", address(distributor));

        vm.stopBroadcast();

        console.log("\n=== ARES Protocol Deployed ===");
        console.log("Remember to:");
        console.log("1. Transfer treasury funds to TimelockEngine");
        console.log("2. Transfer reward tokens to RewardDistributor");
        console.log("3. Set ProposalManager as governance of TimelockEngine and GovernanceGuard");
    }
}
