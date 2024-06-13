// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {Vault} from "src/Vault.sol";
import {SIR} from "src/SIR.sol";
import {ErrorComputation} from "./ErrorComputation.sol";

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
            if (contributorsFR_[i].contribution > 0) {
                // console.log(
                //     "Contributor: ",
                //     contributorsFR_[i].addr,
                //     " Contribution: ",
                //     contributorsFR_[i].contribution
                // );
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

    // function testFuzz_funraisingContributorMint(uint256 contributor, uint32 timeSkip) public {
    //     ContributorFR memory contributorFR = _getContributorFR(contributor);

    //     // Skip time
    //     skip(timeSkip);

    //     // Fake contributor mint
    //     assertEq(sir.contributorUnclaimedSIR(contributor), 0);

    //     // Attempt to mint
    //     vm.prank(contributor);
    //     vm.expectRevert();
    //     sir.contributorMint();
    // }

    function testFuzz_preMainnetContributorMint(uint256 contributor, uint32 timeSkip) public {
        ContributorPreMainnet memory contributorPreMainnet = _getContributorPreMainnet(contributor);

        // Skip time
        skip(timeSkip);

        // Issuance
        uint256 issuance = (contributorPreMainnet.allocation * SystemConstants.ISSUANCE) / 100000;

        // Fake contributor mint
        assertEq(sir.contributorUnclaimedSIR(contributorPreMainnet.addr), 0);

        // Attempt to mint
        vm.prank(contributorPreMainnet.addr);
        vm.expectRevert();
        sir.contributorMint();
    }

    function _getContributorFR(uint256 index) internal view returns (ContributorFR memory) {
        return contributorsFR[_bound(index, 0, contributorsFR.length - 1)];
    }

    function _getContributorPreMainnet(uint256 index) internal view returns (ContributorPreMainnet memory) {
        return contributorsPreMainnet[_bound(index, 0, contributorsPreMainnet.length - 1)];
    }
}
