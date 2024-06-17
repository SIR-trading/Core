// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {SIR} from "src/SIR.sol";
import {ErrorComputation} from "./ErrorComputation.sol";
import {Contributors} from "src/libraries/Contributors.sol";

contract ContributorsTest is Test {
    struct ContributorFR {
        uint256 contribution;
        address addr;
        uint256 numBC;
    }

    struct ContributorPreMainnet {
        uint256 allocation;
        address addr;
    }

    uint256 constant THREE_YEARS = 3 * 365 * 24 * 60 * 60;
    uint256 constant FUNDRAISING_PERCENTAGE = 10; // 10% of the issuance reserved for fundraising
    uint256 constant BC_BOOST = 5; // [%] 5% boost per BC
    uint256 constant MAX_NUM_BC = 6; // Maximum number of BCs for boost

    uint256 fundraisingTotal = 0;

    SIR public sir;

    address alice = vm.addr(1);
    address bob = vm.addr(2);
    address charlie = vm.addr(3);

    ContributorFR[] contributorsFR;
    ContributorPreMainnet[] contributorsPreMainnet;
    mapping(address => bool) existsContributor;

    function setUp() public {
        // vm.createSelectFork("mainnet", 18128102);
        vm.warp(4269);

        // Deploy SIR
        sir = new SIR(Addresses.ADDR_WETH);

        // Deploy Vault
        address vault = address(new Vault(vm.addr(10), address(sir), vm.addr(11)));

        // Initialize SIR
        sir.initialize(vault);

        // Get fundrasing contributors
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contributors/fundraising.json"));
        bytes memory data = vm.parseJson(json);
        ContributorFR[] memory contributorsFR_ = abi.decode(data, (ContributorFR[]));
        for (uint256 i = 0; i < contributorsFR_.length; i++) {
            // Sum total fundraising
            fundraisingTotal += contributorsFR_[i].contribution;

            // Limit the number of BCs
            if (contributorsFR_[i].numBC > MAX_NUM_BC) contributorsFR_[i].numBC = MAX_NUM_BC;

            // Add the contributor if the contribution is greater than 0
            if (contributorsFR_[i].contribution > 0) {
                contributorsFR.push(contributorsFR_[i]);

                // Indicate that the contributors exist
                existsContributor[contributorsFR_[i].addr] = true;
            }
        }

        // Get pre-mainnet contributors
        json = vm.readFile(string.concat(vm.projectRoot(), "/contributors/pre_mainnet.json"));
        data = vm.parseJson(json);
        ContributorPreMainnet[] memory contributorsPreMainnet_ = abi.decode(data, (ContributorPreMainnet[]));
        for (uint256 i = 0; i < contributorsPreMainnet_.length; i++) {
            if (contributorsPreMainnet_[i].allocation > 0) {
                // console.log(
                //     "Contributor: ",
                //     contributorsPreMainnet_[i].addr,
                //     " Allocation: ",
                //     contributorsPreMainnet_[i].allocation
                // );
                contributorsPreMainnet.push(contributorsPreMainnet_[i]);

                // Indicate that the contributors exist
                existsContributor[contributorsPreMainnet_[i].addr] = true;
            }
        }
    }

    function test_getAllocation() public {
        uint256 aggContributions = 0;

        for (uint256 i = 0; i < contributorsFR.length; i++) {
            aggContributions += Contributors.getAllocation(contributorsFR[i].addr);
            console.log(aggContributions);
        }

        for (uint256 i = 0; i < contributorsPreMainnet.length; i++) {
            aggContributions += Contributors.getAllocation(contributorsPreMainnet[i].addr);
            console.log(aggContributions);
        }

        assertEq(aggContributions, type(uint56).max); // This works for now but most likely it needs some error tolerance.
    }

    function testFuzz_fakeContributorMint(address contributor, uint32 timeSkip) public {
        vm.assume(!existsContributor[contributor]);

        // Skip time
        skip(timeSkip);

        // Fake contributor mint
        assertEq(sir.contributorUnclaimedSIR(contributor), 0);

        // Attempt to mint
        vm.prank(contributor);
        vm.expectRevert();
        sir.contributorMint();
    }

    // function testFuzz_funraisingContributorMint(uint256 contributor, uint32 timeSkip, uint32 timeSkip2) public {
    //     ContributorFR memory contributorFR = _getContributorFR(contributor);

    //     // Skip time
    //     skip(timeSkip);

    //     // Issuance
    //     uint256 issuance = (((contributorFR.contribution * SystemConstants.ISSUANCE) * FUNDRAISING_PERCENTAGE) *
    //         (100 + BC_BOOST * contributorFR.numBC)) / (fundraisingTotal * (100 ^ 2));

    //     // Contributor's rewards
    //     uint256 rewards = issuance * (timeSkip <= THREE_YEARS ? timeSkip : THREE_YEARS);
    //     assertEq(sir.contributorUnclaimedSIR(contributorFR.addr), rewards);

    //     // Mint contributor's rewards
    //     vm.prank(contributorFR.addr);
    //     if (timeSkip == 0) vm.expectRevert();
    //     uint256 rewards_ = sir.contributorMint();

    //     // Assert rewards
    //     assertEq(rewards_, rewards);
    //     assertEq(sir.contributorUnclaimedSIR(contributorFR.addr), 0);

    //     // Skip time
    //     skip(timeSkip2);

    //     // Contributor's rewards
    //     rewards =
    //         issuance *
    //         (
    //             uint256(timeSkip) + timeSkip2 <= THREE_YEARS
    //                 ? timeSkip2
    //                 : (timeSkip <= THREE_YEARS ? THREE_YEARS - timeSkip : 0)
    //         );
    //     assertEq(sir.contributorUnclaimedSIR(contributorFR.addr), rewards);
    // }

    function testFuzz_preMainnetContributorMint(uint256 contributor, uint32 timeSkip, uint32 timeSkip2) public {
        ContributorPreMainnet memory contributorPreMainnet = _getContributorPreMainnet(contributor);

        // Skip time
        skip(timeSkip);

        // Issuance
        uint256 issuance = (contributorPreMainnet.allocation * SystemConstants.ISSUANCE) / 100000;

        // Contributor's rewards
        uint256 rewards = issuance * (timeSkip <= THREE_YEARS ? timeSkip : THREE_YEARS);
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), rewards);

        // Mint contributor's rewards
        vm.prank(contributorPreMainnet.addr);
        if (timeSkip == 0) vm.expectRevert();
        uint256 rewards_ = sir.contributorMint();

        // Assert rewards
        assertEq(rewards_, rewards);
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), 0);

        // Skip time
        skip(timeSkip2);

        // Contributor's rewards
        rewards =
            issuance *
            (
                uint256(timeSkip) + timeSkip2 <= THREE_YEARS
                    ? timeSkip2
                    : (timeSkip <= THREE_YEARS ? THREE_YEARS - timeSkip : 0)
            );
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), rewards);
    }

    function _getContributorFR(uint256 index) internal view returns (ContributorFR memory) {
        return contributorsFR[_bound(index, 0, contributorsFR.length - 1)];
    }

    function _getContributorPreMainnet(uint256 index) internal view returns (ContributorPreMainnet memory) {
        return contributorsPreMainnet[_bound(index, 0, contributorsPreMainnet.length - 1)];
    }
}
